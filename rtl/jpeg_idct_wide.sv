// jpeg_idct_wide.sv - 8x8 inverse DCT of the WIDE build (FAST = 2): one block every 8 clocks.
//
// Same arithmetic as jpeg_idct_fast (libjpeg's jpeg_idct_islow, bit-exact), with two pipelined
// 1-D cores (jpeg_idct1d): pass 1 transforms one column per clock, pass 2 one row per clock.
//
//   coefficient slots (4 x 64, 8 row banks, valid masks) --column/clk--> jpeg_idct1d PASS 1
//     --> workspace (3 x 64 registers) --row/clk--> jpeg_idct1d PASS 2 --> one 64-bit word per row
//
// Coefficient slots: the entropy decoder writes the non-zero coefficients of a block into a clean
// slot (cw_slot) and then commits it (cw_commit, slots in order 0, 1, 2, 3, 0 ...) with a
// descriptor.  Each slot has a 64-bit valid mask set by the writes; a coefficient whose bit is
// clear reads as zero, so a slot is clean again as soon as pass 1 has read it (its mask is
// cleared in that clock): no zeroing pass.
// Pass 1 reads column c of the oldest committed slot from the 8 row banks (registered read), and
// writes the column of 16-bit results into a free workspace buffer six clocks later.  A buffer
// whose 8 columns are written is ready for pass 2, which starts when the block's destination is
// writable (p2_ok, as in jpeg_idct_fast) and reads one row per clock (registered); its samples
// are written as one word (sample i in bits 8i+7..8i) at p2_base + row * p2_pitch.  The
// descriptor travels from the slot to the workspace buffer to the pass-2 request (p2_desc);
// from there on only the short tag (p2_tag) follows the block to smp_tag and blk_done.
// Based in part on the work of the Independent JPEG Group: the arithmetic reproduces libjpeg /
// libjpeg-turbo so that the output is bit-identical to them (see NOTICE.md).
module jpeg_idct_wide #(
  parameter int DW  = 12,             // descriptor width
  parameter int TW  = 5,              // tag width
  parameter int SAW = 7               // sample word address width (64-bit words)
) (
  input  logic           clk,
  input  logic           rst,
  // coefficient slots
  output logic [3:0]     clean,       // slot s may be filled
  input  logic           cw_we,
  input  logic [1:0]     cw_slot,
  input  logic [5:0]     cw_addr,     // natural index 8*row + col
  input  logic signed [15:0] cw_data,
  input  logic           cw_commit,   // pulse: slot cw_cslot holds a complete block (after its last write)
  input  logic [1:0]     cw_cslot,
  input  logic [DW-1:0]  cw_desc,
  // pass 2 destination handshake: the next block for pass 2 and its destination
  output logic           p2_pending,
  output logic [DW-1:0]  p2_desc,
  input  logic           p2_ok,       // destination writable
  input  logic [SAW-1:0] p2_base,     // word address of sample row 0 (combinational from p2_desc)
  input  logic [SAW-1:0] p2_pitch,    // words per sample row
  input  logic [TW-1:0]  p2_tag,      // carried to smp_tag / blk_tag
  // sample words
  output logic           smp_we,
  output logic [SAW-1:0] smp_addr,
  output logic [63:0]    smp_data,
  output logic [TW-1:0]  smp_tag,
  output logic           blk_done,    // pulse: last row of a block written
  output logic [TW-1:0]  blk_tag,
  output logic           busy         // a block is somewhere in the IDCT
);
  // ================================================================ coefficient slots
  logic [3:0]    full;                // committed, not yet read by pass 1
  logic [63:0]   vmask [0:3];
  logic [DW-1:0] desc_c [0:3];
  logic [1:0]    rp;                  // next slot for pass 1
  assign clean = ~full;               // (the decoder tracks which clean slot it is filling)

  logic        r1_act;                // pass 1 reading slot r1_slot, column r1_col this clock
  logic [1:0]  r1_slot, r1_ws;
  logic [2:0]  r1_col;
  logic signed [15:0] cb_q [0:7];     // column read (registered)
  logic [7:0]  vb_q;                  // valid bits of the column read
  genvar gr;
  generate
    for (gr = 0; gr < 8; gr = gr + 1) begin : g_cbank
      logic signed [15:0] mem [0:31];  // {slot, column}
      always_ff @(posedge clk) begin
        if (cw_we && cw_addr[5:3] == gr) mem[{cw_slot, cw_addr[2:0]}] <= cw_data;
        cb_q[gr] <= mem[{r1_slot, r1_col}];
      end
    end
  endgenerate

  // ================================================================ workspace (3 buffers of 8x8)
  logic signed [15:0] ws [0:2][0:7][0:7];   // [buffer][row][column]
  logic [2:0]    ws_p1, ws_rdy, ws_p2;      // owned by pass 1 / ready / owned by pass 2
  logic [DW-1:0] desc_w [0:2];
  logic [1:0]    w1n, g2n;                  // next buffer for pass 1 / pass 2
  function automatic logic [1:0] nxt3(input logic [1:0] b);
    nxt3 = (b == 2'd2) ? 2'd0 : b + 2'd1;
  endfunction

  // ================================================================ pass 1 core
  // tag: {last column, buffer, column}
  logic        c1_in_v, c1_out_v;
  logic [5:0]  c1_in_t, c1_out_t;
  logic signed [15:0] c1x [0:7];
  logic [15:0] c1y [0:7];
  logic        q1_act, q1_last;         // the column read last clock enters the core now
  logic [1:0]  q1_ws;
  logic [2:0]  q1_col;
  always_comb begin : g_c1x
    integer r;
    for (r = 0; r < 8; r = r + 1) c1x[r] = vb_q[r] ? cb_q[r] : 16'sd0;
  end
  assign c1_in_v = q1_act;
  assign c1_in_t = {q1_last, q1_ws, q1_col};
  jpeg_idct1d #(.PASS(1), .TW(6)) u_p1 (
    .clk(clk), .rst(rst), .in_valid(c1_in_v), .in_tag(c1_in_t),
    .x0(c1x[0]), .x1(c1x[1]), .x2(c1x[2]), .x3(c1x[3]), .x4(c1x[4]), .x5(c1x[5]), .x6(c1x[6]), .x7(c1x[7]),
    .out_valid(c1_out_v), .out_tag(c1_out_t),
    .y0(c1y[0]), .y1(c1y[1]), .y2(c1y[2]), .y3(c1y[3]), .y4(c1y[4]), .y5(c1y[5]), .y6(c1y[6]), .y7(c1y[7]));

  // ================================================================ pass 2 core
  // tag: {last row, word address, block tag}
  logic        r2_act;                // pass 2 reading row r2_row of buffer r2_ws this clock
  logic [1:0]  r2_ws;
  logic [2:0]  r2_row;
  logic [SAW-1:0] r2_addr, r2_pitch;
  logic [TW-1:0]  r2_tag;
  logic signed [15:0] c2x [0:7];       // row read (registered)
  logic        c2_in_v, c2_out_v;
  logic [SAW+TW:0] c2_in_t, c2_out_t;
  logic [15:0] c2y [0:7];
  jpeg_idct1d #(.PASS(2), .TW(SAW + TW + 1)) u_p2 (
    .clk(clk), .rst(rst), .in_valid(c2_in_v), .in_tag(c2_in_t),
    .x0(c2x[0]), .x1(c2x[1]), .x2(c2x[2]), .x3(c2x[3]), .x4(c2x[4]), .x5(c2x[5]), .x6(c2x[6]), .x7(c2x[7]),
    .out_valid(c2_out_v), .out_tag(c2_out_t),
    .y0(c2y[0]), .y1(c2y[1]), .y2(c2y[2]), .y3(c2y[3]), .y4(c2y[4]), .y5(c2y[5]), .y6(c2y[6]), .y7(c2y[7]));

  assign p2_pending = ws_rdy[g2n];
  assign p2_desc    = desc_w[g2n];

  // sample words: pass-2 results go straight to the write port
  assign smp_we   = c2_out_v;
  assign smp_addr = c2_out_t[SAW+TW-1:TW];
  assign smp_tag  = c2_out_t[TW-1:0];
  assign smp_data = {c2y[7][7:0], c2y[6][7:0], c2y[5][7:0], c2y[4][7:0], c2y[3][7:0], c2y[2][7:0], c2y[1][7:0], c2y[0][7:0]};
  assign blk_done = c2_out_v && c2_out_t[SAW+TW];
  assign blk_tag  = c2_out_t[TW-1:0];

  logic p1_inflight, p2_inflight;     // a column / row is somewhere in a core
  assign busy = (|full) || r1_act || q1_act || p1_inflight || (|ws_p1) || (|ws_rdy) || (|ws_p2) || r2_act
             || c2_in_v || p2_inflight;

  // ================================================================ sequencing
  always_ff @(posedge clk) begin : g_seq
    integer i, r, c;
    if (rst) begin
      full <= '0; rp <= '0; r1_act <= 1'b0; r1_slot <= '0; r1_ws <= '0; r1_col <= '0;
      q1_act <= 1'b0; q1_last <= 1'b0; q1_ws <= '0; q1_col <= '0; vb_q <= '0;
      ws_p1 <= '0; ws_rdy <= '0; ws_p2 <= '0; w1n <= '0; g2n <= '0;
      r2_act <= 1'b0; r2_ws <= '0; r2_row <= '0; r2_addr <= '0; r2_pitch <= '0; r2_tag <= '0;
      c2_in_v <= 1'b0; c2_in_t <= '0;
      for (i = 0; i < 4; i = i + 1) vmask[i] <= '0;
    end else begin
      // ---- writes and commits from the entropy decoder
      if (cw_we) vmask[cw_slot][cw_addr] <= 1'b1;
      if (cw_commit) begin full[cw_cslot] <= 1'b1; desc_c[cw_cslot] <= cw_desc; end

      // ---- pass 1: read the columns of slot rp into a free workspace buffer
      q1_act <= r1_act; q1_last <= (r1_col == 3'd7); q1_ws <= r1_ws; q1_col <= r1_col;
      for (r = 0; r < 8; r = r + 1) vb_q[r] <= vmask[r1_slot][{r[2:0], r1_col}];
      if (r1_act && r1_col != 3'd7) r1_col <= r1_col + 3'd1;
      else begin
        if (r1_act) begin                                  // column 7 read now: the slot is clean
          full[r1_slot] <= 1'b0; vmask[r1_slot] <= '0;
        end
        if (full[rp] && !ws_p1[w1n] && !ws_rdy[w1n] && !ws_p2[w1n]) begin
          r1_act <= 1'b1; r1_slot <= rp; r1_col <= 3'd0; r1_ws <= w1n; rp <= rp + 2'd1;
          ws_p1[w1n] <= 1'b1; desc_w[w1n] <= desc_c[rp]; w1n <= nxt3(w1n);
        end else r1_act <= 1'b0;
      end
      // pass-1 results: column c of buffer b; the last column makes the buffer ready
      if (c1_out_v) begin
        for (r = 0; r < 8; r = r + 1) ws[c1_out_t[4:3]][r][c1_out_t[2:0]] <= c1y[r];
        if (c1_out_t[5]) begin ws_p1[c1_out_t[4:3]] <= 1'b0; ws_rdy[c1_out_t[4:3]] <= 1'b1; end
      end

      // ---- pass 2: read the rows of the next ready buffer once its destination is writable
      c2_in_v <= r2_act;
      c2_in_t <= {r2_row == 3'd7, r2_addr, r2_tag};
      for (c = 0; c < 8; c = c + 1) c2x[c] <= ws[r2_ws][r2_row][c];
      if (r2_act && r2_row != 3'd7) begin
        r2_row <= r2_row + 3'd1; r2_addr <= r2_addr + r2_pitch;
      end else begin
        if (r2_act) ws_p2[r2_ws] <= 1'b0;                  // row 7 read now: the buffer is free
        if (ws_rdy[g2n] && p2_ok) begin
          r2_act <= 1'b1; r2_ws <= g2n; r2_row <= 3'd0; r2_addr <= p2_base; r2_pitch <= p2_pitch; r2_tag <= p2_tag;
          ws_rdy[g2n] <= 1'b0; ws_p2[g2n] <= 1'b1; g2n <= nxt3(g2n);
        end else r2_act <= 1'b0;
      end
    end
  end

  // columns / rows inside the cores (5 clocks each): counted so that `busy` covers them
  logic [2:0] n1, n2;
  assign p1_inflight = (n1 != 3'd0);
  assign p2_inflight = (n2 != 3'd0);
  always_ff @(posedge clk) begin
    if (rst) begin n1 <= '0; n2 <= '0; end
    else begin
      n1 <= n1 + {2'd0, c1_in_v} - {2'd0, c1_out_v};
      n2 <= n2 + {2'd0, c2_in_v} - {2'd0, c2_out_v};
    end
  end
endmodule
