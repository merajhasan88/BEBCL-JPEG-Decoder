// Timing probe 4 (Proposal B, ROADMAP.md): table lookups at every bit offset of a window that moves by
// whole 32-bit words, so the loop holds neither the table read nor the barrel shifter. The lookups at
// offsets 0..63 of the window W (three words) are computed from W's registers (64 copies of the four
// tables); for the next clock the entries at offsets 0..31 of the next window are registered: offsets
// 0..31 of W if W stays, 32..63 if it moves on by a word. The loop: entry LT[ptr][{AC, Th}] -> n ->
// ptr + n -> carry (the window moves). One symbol per clock, one stream. Codes longer than the 8-bit
// tables are left out, as in probe 3.
module hufloop_probe4 (
  input  logic        clk,
  input  logic        rst,
  input  logic        f_valid,           // 32-bit words of the scan (FF00 removed), MSB first
  input  logic [31:0] f_data,
  output logic        f_ready,
  input  logic        lut_we,
  input  logic [9:0]  lut_waddr,         // {Tc, Th, 8 bits}
  input  logic [12:0] lut_wdata,         // {hit, eob, zrl, S != 0, R (4), n = L+S (5)}
  input  logic        th_dc,
  input  logic        th_ac,
  input  logic        run,
  output logic        sym_valid,
  output logic [4:0]  sym_ptr,           // offset of the symbol in the window (its magnitude bits follow)
  output logic [5:0]  k_out,
  output logic        blk_end
);
  logic [95:0] W;                        // W[95] is the bit at offset 0
  logic [12:0] L [0:63][0:3];            // lookups at offset o in table t
  genvar o;
  generate
    for (o = 0; o < 64; o = o + 1) begin : g_off
      logic [12:0] tb0 [0:255], tb1 [0:255], tb2 [0:255], tb3 [0:255];
      always_ff @(posedge clk) if (lut_we) case (lut_waddr[9:8])
        2'd0: tb0[lut_waddr[7:0]] <= lut_wdata;  2'd1: tb1[lut_waddr[7:0]] <= lut_wdata;
        2'd2: tb2[lut_waddr[7:0]] <= lut_wdata;  default: tb3[lut_waddr[7:0]] <= lut_wdata;
      endcase
      logic [7:0] a;
      assign a = W[95 - o -: 8];
      assign L[o][0] = tb0[a]; assign L[o][1] = tb1[a]; assign L[o][2] = tb2[a]; assign L[o][3] = tb3[a];
    end
  endgenerate

  logic [12:0] LT [0:31][0:3];           // registered entries at offsets 0..31 of the current window
  logic [4:0]  ptr;                      // offset of the next symbol
  logic        ph;                       // AC phase
  logic [6:0]  k;
  logic        th;
  assign th = ph ? th_ac : th_dc;
  logic [12:0] e;
  assign e = LT[ptr][{ph, th}];
  logic       hit, eob, zrl, snz;
  logic [3:0] R;
  logic [4:0] n;
  assign {hit, eob, zrl, snz, R, n} = e;
  logic [5:0] np;
  assign np = {1'b0, ptr} + {1'b0, n};
  logic moved, go;
  assign moved   = np[5];                // the symbol ends in the next word: the window moves on
  assign go      = run && hit && (!moved || f_valid);
  assign f_ready = go && moved;
  logic [3:0] r;
  assign r = ph ? R : 4'd0;
  logic [7:0] kn;
  assign kn = {1'b0, k} + {4'd0, r} + 8'd1;
  logic last;
  assign last = ph && (eob || kn > 8'd63);

  always_ff @(posedge clk) begin : p_loop
    integer i, t;
    if (rst) begin
      W <= '0; ptr <= '0; ph <= 1'b0; k <= '0;
      sym_valid <= 1'b0; sym_ptr <= '0; k_out <= '0; blk_end <= 1'b0;
    end else begin
      for (i = 0; i < 32; i = i + 1)
        for (t = 0; t < 4; t = t + 1)
          LT[i][t] <= (go && moved) ? L[i + 32][t] : L[i][t];
      if (go && moved) W <= {W[63:0], f_data};
      if (go) begin
        ptr <= np[4:0];
        if (!ph) begin ph <= 1'b1; k <= 7'd1; end
        else if (last) begin ph <= 1'b0; k <= 7'd0; end
        else if (zrl) k <= k + 7'd16;
        else k <= kn[6:0];
      end
      sym_valid <= go; sym_ptr <= ptr; k_out <= k[5:0]; blk_end <= go && last;
    end
  end
endmodule
