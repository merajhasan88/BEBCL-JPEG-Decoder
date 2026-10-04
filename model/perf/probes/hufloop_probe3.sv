// Timing probe 3 (Proposal B, ROADMAP.md): the loop of probe 2 cut by one register and shared by two
// independent streams ("C-slow", C = 2). Stage L looks up stream X's window while stage S shifts stream
// Y's window by its symbol's n = L + S; the streams swap every clock, so each stream decodes one symbol
// every two clocks and the pair one symbol per clock - at the shorter loop's clock. The two streams
// are segments of one scan (Proposal A) or two files. Codes longer than the 8-bit table (slow path)
// are left out here: in probe 2 they add only registered terms to the loop.
module hufloop_probe3 (
  input  logic        clk,
  input  logic        rst,
  input  logic [1:0]  f_valid,           // per stream: 32-bit words of the scan (FF00 removed), MSB first
  input  logic [63:0] f_data,            // stream 1 in bits 63:32
  output logic [1:0]  f_ready,
  input  logic        lut_we,
  input  logic [9:0]  lut_waddr,         // {Tc, Th, 8 bits}
  input  logic [17:0] lut_wdata,         // {hit, eob, n = L+S (5), L-1 (3), HUFFVAL (8)}
  input  logic        th_dc,
  input  logic        th_ac,
  input  logic        run,
  output logic        sym_valid,
  output logic        sym_sid,           // the stream of the symbol
  output logic [7:0]  sym_out,
  output logic [5:0]  k_out,
  output logic [31:0] mag_win,
  output logic        blk_end
);
  logic [17:0] t0 [0:255], t1 [0:255], t2 [0:255], t3 [0:255];
  always_ff @(posedge clk) if (lut_we) case (lut_waddr[9:8])
    2'd0: t0[lut_waddr[7:0]] <= lut_wdata;  2'd1: t1[lut_waddr[7:0]] <= lut_wdata;
    2'd2: t2[lut_waddr[7:0]] <= lut_wdata;  default: t3[lut_waddr[7:0]] <= lut_wdata;
  endcase

  // ring of two stages; r0 = the stream entering stage L, r1 = the stream entering stage S
  logic [63:0] D0, D1;                   // windows, next bit = D[63]
  logic [6:0]  v0, v1;                   // valid bits
  logic        ph0, ph1;                 // AC phase
  logic [6:0]  k0, k1;
  logic        s0, s1;                   // stream ids
  logic [17:0] ent1;                     // stage L's table entry for the stream in r1
  logic        have1;

  // ---- stage L: refill (registered v only), table lookup at D0[63:56], late select {AC, Th}
  logic        merge;
  logic [31:0] fw;
  logic [63:0] Dm;
  logic [6:0]  vm;
  assign fw      = s0 ? f_data[63:32] : f_data[31:0];
  assign merge   = (s0 ? f_valid[1] : f_valid[0]) && (v0 <= 7'd32);
  assign f_ready = {merge && s0, merge && !s0};
  assign Dm = merge ? (D0 | ({fw, 32'd0} >> v0)) : D0;
  assign vm = merge ? v0 + 7'd32 : v0;
  logic [7:0]  a;
  assign a = D0[63:56];
  logic [17:0] e0, e1, e2, e3, ent;
  assign e0 = t0[a]; assign e1 = t1[a]; assign e2 = t2[a]; assign e3 = t3[a];
  logic th;
  assign th = ph0 ? th_ac : th_dc;
  always_comb case ({ph0, th})
    2'd0: ent = e0; 2'd1: ent = e1; 2'd2: ent = e2; default: ent = e3;
  endcase

  // ---- stage S: shift by n, symbol bookkeeping
  logic        hit, go, eob;
  logic [4:0]  n;
  logic [7:0]  sym;
  assign hit = ent1[17];
  assign eob = ent1[16];
  assign n   = ent1[15:11];
  assign sym = ent1[7:0];
  assign go  = run && have1 && hit;
  logic [3:0] r;
  assign r = ph1 ? sym[7:4] : 4'd0;
  logic [7:0] kn;
  assign kn = {1'b0, k1} + {4'd0, r} + 8'd1;
  logic zrl, last;
  assign zrl  = ph1 && sym[3:0] == 4'd0 && r == 4'hF;
  assign last = (ph1 && (eob || kn > 8'd63));

  always_ff @(posedge clk) begin
    if (rst) begin
      D0 <= '0; v0 <= '0; ph0 <= 1'b0; k0 <= '0; s0 <= 1'b0;
      D1 <= '0; v1 <= '0; ph1 <= 1'b0; k1 <= '0; s1 <= 1'b1; ent1 <= '0; have1 <= 1'b0;
      sym_valid <= 1'b0; sym_sid <= 1'b0; sym_out <= '0; k_out <= '0; mag_win <= '0; blk_end <= 1'b0;
    end else begin
      // stage L -> r1
      D1 <= Dm; v1 <= vm; ph1 <= ph0; k1 <= k0; s1 <= s0; ent1 <= ent; have1 <= (v0 >= 7'd27);
      // stage S -> r0 (the same stream, its next symbol)
      D0 <= go ? (D1 << n) : D1;
      v0 <= go ? v1 - {2'b00, n} : v1;
      s0 <= s1;
      if (go) begin
        if (!ph1) begin ph0 <= 1'b1; k0 <= 7'd1; end
        else if (last) begin ph0 <= 1'b0; k0 <= 7'd0; end
        else if (zrl) begin ph0 <= ph1; k0 <= k1 + 7'd16; end
        else begin ph0 <= ph1; k0 <= kn[6:0]; end
      end else begin ph0 <= ph1; k0 <= k1; end
      sym_valid <= go; sym_sid <= s1; sym_out <= sym; k_out <= k1[5:0]; blk_end <= go && last;
      mag_win <= D1[63:32];
    end
  end
endmodule
