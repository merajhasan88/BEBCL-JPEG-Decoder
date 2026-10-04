// Timing probe: the 1-symbol-per-clock Huffman loop planned for the wide core (FAST=2).
// Loop: bit count -> next 8 bits of the window -> lookahead table (asynchronous read) ->
// code length L + magnitude size S -> bit count (and run / DC-AC state -> table address).
module hufloop_probe1 (
  input  logic        clk,
  input  logic        rst,
  input  logic        in_valid,          // bytes from the parser (FF00 already removed)
  input  logic [7:0]  in_data,
  output logic        in_ready,
  input  logic        lut_we,            // lookahead tables, written by the parser
  input  logic [9:0]  lut_waddr,         // {Tc, Th, 8 bits}
  input  logic [11:0] lut_wdata,         // {hit, L-1, HUFFVAL}
  input  logic        mc_we,             // MAXCODE+1 of lengths 9..16 for the slow path
  input  logic [4:0]  mc_waddr,          // {Tc, Th, L-9}
  input  logic [16:0] mc_wdata,
  input  logic        th_dc,             // block descriptor (queued one block ahead in the core)
  input  logic        th_ac,
  input  logic        run,
  output logic        sym_valid,
  output logic [7:0]  sym_out,
  output logic [5:0]  k_out,
  output logic [15:0] mag_bits,
  output logic        blk_end,
  output logic [4:0]  slow_len
);
  logic [63:0] acc;                      // next bit = acc[wcnt-1]
  logic [6:0]  wcnt;
  logic        phase_ac, have;
  logic [6:0]  k;

  (* ram_style = "distributed" *) logic [11:0] lut [0:1023];
  always_ff @(posedge clk) if (lut_we) lut[lut_waddr] <= lut_wdata;
  logic [16:0] maxc [0:31];
  always_ff @(posedge clk) if (mc_we) maxc[mc_waddr] <= mc_wdata;

  logic [79:0] accx;
  assign accx = {acc, 16'd0} >> wcnt;                  // accx[15:0]: the next 16 bits
  logic th;
  assign th = phase_ac ? th_ac : th_dc;
  logic [11:0] ent;
  assign ent = lut[{phase_ac, th, accx[15:8]}];

  // slow path state: a miss is resolved in 2 clocks by comparing all 8 lengths at once
  logic        slow1, slow2;
  logic [15:0] sview;
  logic [4:0]  slen;
  logic        slow_found;
  always_comb begin
    slen = 5'd16; slow_found = 1'b0;
    for (int unsigned l = 9; l <= 16; l++)
      if (!slow_found && ({1'b0, sview >> (16 - l)} < maxc[{phase_ac, th, l[2:0] - 3'd1}])) begin slen = l[4:0]; slow_found = 1'b1; end
  end

  logic        hit, go;
  logic [4:0]  L;
  logic [3:0]  s, r;
  logic [5:0]  n;
  logic [7:0]  sym;
  always_comb begin
    hit = ent[11];
    if (slow2) begin L = slen; sym = sview[7:0] ^ {3'd0, slen}; end   // (HUFFVAL read stands in)
    else begin L = {2'b00, ent[10:8]} + 5'd1; sym = ent[7:0]; end
    s = sym[3:0];
    r = phase_ac ? sym[7:4] : 4'd0;
    n = {1'b0, L} + {2'b00, s};
    go = run && have && (hit || slow2) && !slow1;
  end
  logic [7:0] kn;
  assign kn = {1'b0, k} + {4'd0, r} + 8'd1;
  logic eob, zrl, last;
  assign eob  = phase_ac && s == 4'd0 && r != 4'hF;
  assign zrl  = phase_ac && s == 4'd0 && r == 4'hF;
  assign last = eob || (phase_ac && kn > 8'd63) || (phase_ac && zrl && k > 7'd47);

  logic take;
  assign take = in_valid && wcnt <= 7'd56;
  assign in_ready = take;
  logic [6:0] wnext;
  assign wnext = wcnt - (go ? {1'b0, n} : 7'd0) + (take ? 7'd8 : 7'd0);

  always_ff @(posedge clk) begin
    if (rst) begin
      acc <= '0; wcnt <= '0; phase_ac <= 1'b0; have <= 1'b0; k <= '0; slow1 <= 1'b0; slow2 <= 1'b0; sview <= '0;
      sym_valid <= 1'b0; sym_out <= '0; k_out <= '0; mag_bits <= '0; blk_end <= 1'b0; slow_len <= '0;
    end else begin
      if (take) acc <= {acc[55:0], in_data};
      wcnt <= wnext;
      have <= wnext >= 7'd27;
      slow1 <= run && have && !hit && !slow1 && !slow2;
      if (run && have && !hit && !slow1 && !slow2) sview <= accx[15:0];
      slow2 <= slow1;
      sym_valid <= go; sym_out <= sym; k_out <= k[5:0]; blk_end <= go && last; slow_len <= slen;
      mag_bits <= accx[15:0];                               // (stage E1 reads the magnitude from here)
      if (go) begin
        if (!phase_ac) begin phase_ac <= 1'b1; k <= 7'd1; end
        else if (last) begin phase_ac <= 1'b0; k <= 7'd0; end
        else if (zrl) k <= k + 7'd16;
        else k <= kn[6:0];
      end
    end
  end
endmodule
