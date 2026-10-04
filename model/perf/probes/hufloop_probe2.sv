// Timing probe 2: MSB-aligned window.  Loop: window top 8 bits -> 4 lookahead tables (async) ->
// late select {AC, Th} -> n = L + S (stored in the table) -> window << n.
module hufloop_probe2 (
  input  logic        clk,
  input  logic        rst,
  input  logic        f_valid,           // 32-bit words of the scan (FF00 removed), MSB first
  input  logic [31:0] f_data,
  output logic        f_ready,
  input  logic        lut_we,
  input  logic [9:0]  lut_waddr,         // {Tc, Th, 8 bits}
  input  logic [17:0] lut_wdata,         // {hit, eob, n = L+S (5), L-1 (3), HUFFVAL (8)}
  input  logic        mc_we,
  input  logic [4:0]  mc_waddr,
  input  logic [16:0] mc_wdata,
  input  logic        th_dc,
  input  logic        th_ac,
  input  logic        run,
  output logic        sym_valid,
  output logic [7:0]  sym_out,
  output logic [5:0]  k_out,
  output logic [31:0] mag_win,
  output logic        blk_end,
  output logic [4:0]  slow_len
);
  logic [63:0] D;                        // next bit = D[63]
  logic [6:0]  v;                        // valid bits
  logic        phase_ac;
  logic [6:0]  k;

  // four 256-entry tables read in parallel, selected late
  logic [17:0] t0 [0:255], t1 [0:255], t2 [0:255], t3 [0:255];
  always_ff @(posedge clk) if (lut_we) case (lut_waddr[9:8])
    2'd0: t0[lut_waddr[7:0]] <= lut_wdata;  2'd1: t1[lut_waddr[7:0]] <= lut_wdata;
    2'd2: t2[lut_waddr[7:0]] <= lut_wdata;  default: t3[lut_waddr[7:0]] <= lut_wdata;
  endcase
  logic [16:0] maxc [0:31];
  always_ff @(posedge clk) if (mc_we) maxc[mc_waddr] <= mc_wdata;

  logic [7:0]  a;
  assign a = D[63:56];
  logic [17:0] e0, e1, e2, e3, ent;
  assign e0 = t0[a]; assign e1 = t1[a]; assign e2 = t2[a]; assign e3 = t3[a];
  logic th;
  assign th = phase_ac ? th_ac : th_dc;
  always_comb case ({phase_ac, th})
    2'd0: ent = e0; 2'd1: ent = e1; 2'd2: ent = e2; default: ent = e3;
  endcase

  // refill: merge the next word right after the valid bits (uses registered v only)
  logic        merge;
  logic [63:0] Dm;
  logic [6:0]  vm;
  assign merge   = f_valid && (v <= 7'd32);
  assign f_ready = merge;
  assign Dm = merge ? (D | ({f_data, 32'd0} >> v)) : D;
  assign vm = merge ? v + 7'd32 : v;

  logic have;
  assign have = (v >= 7'd27);            // any code + magnitude fits (from the register)

  // slow path (codes > 8 bits): parallel MAXCODE compare on the captured window, 2 clocks
  logic        slow1, slow2;
  logic [15:0] sview;
  logic [4:0]  slen, slen_r;
  logic        slow_found;
  logic [3:0]  ss_r;
  always_comb begin
    slen = 5'd16; slow_found = 1'b0;
    for (int unsigned l = 9; l <= 16; l++)
      if (!slow_found && ({1'b0, sview >> (16 - l)} < maxc[{phase_ac, th, l[2:0] - 3'd1}])) begin slen = l[4:0]; slow_found = 1'b1; end
  end

  logic        hit, go, eob;
  logic [4:0]  n;
  logic [7:0]  sym;
  always_comb begin
    hit = ent[17];
    eob = ent[16];
    if (slow2) begin n = slen_r + {1'b0, ss_r}; sym = {sview[7:4], ss_r}; end
    else begin n = ent[15:11]; sym = ent[7:0]; end
    go = run && have && (hit || slow2) && !slow1;
  end
  logic [3:0] r;
  assign r = phase_ac ? sym[7:4] : 4'd0;
  logic [7:0] kn;
  assign kn = {1'b0, k} + {4'd0, r} + 8'd1;
  logic zrl, last;
  assign zrl  = phase_ac && sym[3:0] == 4'd0 && r == 4'hF;
  assign last = (phase_ac && (eob || kn > 8'd63));

  always_ff @(posedge clk) begin
    if (rst) begin
      D <= '0; v <= '0; phase_ac <= 1'b0; k <= '0; slow1 <= 1'b0; slow2 <= 1'b0; sview <= '0; slen_r <= '0; ss_r <= '0;
      sym_valid <= 1'b0; sym_out <= '0; k_out <= '0; mag_win <= '0; blk_end <= 1'b0; slow_len <= '0;
    end else begin
      D <= go ? (Dm << n) : Dm;
      v <= go ? vm - {2'b00, n} : vm;
      slow1 <= run && have && !hit && !slow1 && !slow2;
      if (run && have && !hit && !slow1 && !slow2) sview <= D[63:48];
      slow2 <= slow1; slen_r <= slen; ss_r <= sview[3:0];
      sym_valid <= go; sym_out <= sym; k_out <= k[5:0]; blk_end <= go && last; slow_len <= slen;
      mag_win <= D[63:32];                                   // stage E1 takes the magnitude from here
      if (go) begin
        if (!phase_ac) begin phase_ac <= 1'b1; k <= 7'd1; end
        else if (last) begin phase_ac <= 1'b0; k <= 7'd0; end
        else if (zrl) k <= k + 7'd16;
        else k <= kn[6:0];
      end
    end
  end
endmodule
