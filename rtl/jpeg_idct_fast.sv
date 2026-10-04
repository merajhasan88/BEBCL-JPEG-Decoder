// jpeg_idct_fast.sv - pipelined 8x8 inverse DCT for the FAST build: one block every 32 clocks.
//
// Same arithmetic as jpeg_idct (a bit-exact port of libjpeg's jpeg_idct_islow: CONST_BITS=13,
// PASS1_BITS=2, RANGE_BITS=2, columns first, 16-bit workspace), organised as a two-pass
// pipeline around one shared 1-D transform (12 multipliers):
//
//   coefficient slots (4 x 64, two row-parity banks)  --G1-->  1-D core  --W1-->  workspace (2 x 64)
//   workspace                                          --G2-->  1-D core  --W2-->  sample words
//
// Everything runs on a 4-clock period (phase 0..3).  G1 reads one column per period (two
// coefficients per clock, rows 2i and 2i+1 from the two banks); G2 reads one row per period from
// the workspace, whose element (r, c) sits in bank (r + c) mod 2 so that both the column writes of
// W1 and the row reads of G2 touch both banks.  The core is a pipeline of short stages, each used
// in two phases of the period (pass 1 / pass 2):
//     P  pre-additions (phase 1 / 3)        M  12 products (2 / 0)
//     A1 first adder level (3 / 1)          A2 second adder level (0 / 2)
//     B  outputs, descale, range limit (1 / 3)
// Pass 1 of block n+1 overlaps pass 2 of block n and a block leaves every 8 periods.  Row r of
// pass 2 is written as two 32-bit words (4 samples, sample 4w+i in bits 8i+7..8i) at
// base + r*pitch (+1).
//
// With p2_lb_en the last row (7) of the block is also written to p2_lbase (+1): the raster output
// keeps the last sample row of every MCU row in a line buffer this way.
//
// Coefficient slots: the entropy decoder fills slot `wp` (cw_ready tells whether it is clean),
// commits it with a descriptor; G1 transforms slots in order; afterwards a slot is zeroed in the
// background (2 entries per clock, pausing while the entropy decoder writes) because the decoder
// writes only the non-zero coefficients.  Descriptors are opaque: they come back with the pass-2
// permission request (p2_*); from there on only a short tag (p2_tag, e.g. component and flags)
// travels with the block to the sample writes and blk_done.
// Based in part on the work of the Independent JPEG Group: the arithmetic reproduces libjpeg /
// libjpeg-turbo so that the output is bit-identical to them (see NOTICE.md).
module jpeg_idct_fast #(
  parameter int DW  = 16,             // descriptor width
  parameter int TW  = 4,              // tag width
  parameter int SAW = 7               // sample word address width
) (
  input  logic           clk,
  input  logic           rst,
  // coefficient slot being filled
  output logic           cw_ready,    // slot wp is clean: a block may be decoded into it
  input  logic           cw_we,
  input  logic [5:0]     cw_addr,     // natural index 8*row + col
  input  logic signed [15:0] cw_data,
  input  logic           cw_commit,   // pulse: slot wp holds a complete block (after its last write)
  input  logic [DW-1:0]  cw_desc,
  // pass 2 destination handshake: the next block for pass 2 and its destination
  output logic           p2_pending,
  output logic [DW-1:0]  p2_desc,
  input  logic           p2_ok,       // destination writable
  input  logic [SAW-1:0] p2_base,     // word address of sample row 0 (combinational from p2_desc)
  input  logic [SAW-1:0] p2_pitch,    // words per sample row
  input  logic           p2_lb_en,    // also write row 7 to the line buffer ...
  input  logic [SAW-1:0] p2_lbase,    // ... at this word address
  input  logic [TW-1:0]  p2_tag,      // carried to smp_tag / blk_tag
  // sample words
  output logic           smp_we,
  output logic [SAW-1:0] smp_addr,
  output logic [31:0]    smp_data,
  output logic [TW-1:0]  smp_tag,
  output logic           blk_done,    // pulse: last row of a block written
  output logic [TW-1:0]  blk_tag,
  output logic           busy         // any block inside
);
  localparam int CONST_BITS = 13;
  localparam int PASS1_BITS = 2;

  logic [1:0] ph;                     // free-running phase
  always_ff @(posedge clk) ph <= rst ? 2'd0 : ph + 2'd1;

  // ================================================================ coefficient slots
  logic [3:0]    full, dirty;
  logic [1:0]    wp, rp, zp;
  logic [DW-1:0] desc_c [0:3];
  logic [4:0]    zi;                  // zeroing position: {row pair, column}
  logic          zeroing;
  assign cw_ready = !full[wp] && !dirty[wp];
  assign zeroing  = dirty[zp] && !full[zp];

  logic [6:0]  cb_waddr [0:1], cb_raddr;
  logic        cb_we [0:1];
  logic signed [15:0] cb_wdata [0:1], cb_rdata [0:1];
  logic        g1_act;
  logic [2:0]  g1_col;
  logic [1:0]  g1_slot;
  genvar gb;
  generate
    for (gb = 0; gb < 2; gb = gb + 1) begin : g_cbank
      // entropy decoder writes win; the zeroer uses the port when the decoder does not
      always_comb begin
        if (cw_we) begin
          cb_we[gb] = (cw_addr[3] == gb); cb_waddr[gb] = {wp, cw_addr[5:4], cw_addr[2:0]}; cb_wdata[gb] = cw_data;
        end else begin
          cb_we[gb] = zeroing; cb_waddr[gb] = {zp, zi}; cb_wdata[gb] = 16'sd0;
        end
      end
      jpeg_sdp_ram #(.WIDTH(16), .DEPTH_LOG2(7)) u_cb (
        .clk(clk), .we(cb_we[gb]), .waddr(cb_waddr[gb]), .wdata(cb_wdata[gb]), .raddr(cb_raddr), .rdata(cb_rdata[gb]));
    end
  endgenerate
  assign cb_raddr = {g1_slot, ph, g1_col};           // rows 2*ph (bank 0) and 2*ph+1 (bank 1)

  // ================================================================ workspace (2 slots)
  // slot states: owned by G1 (being written), pending (written, one period to settle), ready for G2
  logic [1:0]  ws_g1, ws_pend, ws_rdy;
  logic [DW-1:0] desc_w [0:1];
  logic        w1n, g2n;              // next workspace slot for G1 / G2
  logic        ws_we;                // write port, registered (one clock after the W1 phase)
  logic [5:0]  ws_waddr [0:1], ws_raddr, ws_waddr_c [0:1];
  logic signed [15:0] ws_wdata [0:1], ws_rdata [0:1], ws_wdata_c [0:1];
  generate
    for (gb = 0; gb < 2; gb = gb + 1) begin : g_wbank
      jpeg_sdp_ram #(.WIDTH(16), .DEPTH_LOG2(6)) u_ws (
        .clk(clk), .we(ws_we), .waddr(ws_waddr[gb]), .wdata(ws_wdata[gb]), .raddr(ws_raddr), .rdata(ws_rdata[gb]));
    end
  endgenerate

  // ================================================================ G1 / G2 state and stage tags
  logic        g1_ws;
  logic        g2_act, g2_ws;
  logic [2:0]  g2_row;
  logic [SAW-1:0] g2_addr, g2_pitch, g2_lbase;
  logic [TW-1:0]  g2_tag;
  logic           g2_lb_en;
  // pass 1: p1 = column just gathered (set at the end of phase 3), q1 = column in stages P..A2
  logic        p1_act, p1_ws, q1_act, q1_ws;  logic [2:0] p1_col, q1_col;
  // pass 2: p2 = row just gathered (end of phase 1), q2 = row in stages P..A2
  logic        p2_act, p2_last, p2_lb, q2_act, q2_last, q2_lb;
  logic [2:0]  p2_row;
  logic [SAW-1:0] p2_addr, p2_lba, q2_addr, q2_lba;
  logic [TW-1:0]  p2_d, q2_d;
  assign ws_raddr   = {g2_ws, g2_row, ph - 2'd2};      // pair (ph-2) mod 4 of row g2_row: columns 2i, 2i+1
  assign p2_pending = ws_rdy[g2n];
  assign p2_desc    = desc_w[g2n];

  // ================================================================ gather registers
  logic signed [15:0] x1 [0:7], x2 [0:7];
  logic signed [15:0] x [0:7];        // stage P input: phase 1 column (pass 1), phase 3 row (pass 2)
  // sums formed while the vector arrives, so that stage P needs one adder level:
  //   s13 = x1 + x5, s02 = x3 + x7 (pass 1 / pass 2), and pass 2's x0 + 16400 (range centre + fudge)
  logic signed [17:0] x1s13, x1s02, x2s13, x2s02, x2_0p;
  logic signed [15:0] w5, w7;         // pass 2: columns 5 and 7 out of the bank swap
  logic               pass1;
  assign pass1 = ~ph[1];
  always_comb begin : g_xsel
    integer i;
    for (i = 0; i < 8; i = i + 1) x[i] = pass1 ? x1[i] : x2[i];
  end

  // ================================================================ 1-D core
  // Mirrors the INT32 arithmetic of jidctint.c; multiplier operands stay <= 18 bits.
  //   tmp0/tmp1 = (x0 +- x4) << 13, plus the pass-1 fudge 1024 (below bit 13, so OR-ed in) or the
  //   pass-2 range centre and fudge (16384 + 16) << 13 folded into the 18-bit sum.
  logic signed [17:0] xe [0:7];
  logic signed [17:0] s26, s02, s13, s03, s12, s0213, s04p, s04m, e_base;
  logic signed [17:0] pa_z1, pa_t2, pa_t3, pa_zz1, pa_zz2, pa_zz3, pa_w1, pa_t0, pa_t3o, pa_w2, pa_t1, pa_t2o;
  logic signed [17:0] pa_e0, pa_e1;   // x0 + x4 (+ 16400), x0 - x4 (+ 16400)
  logic               pa_pass1;
  (* multstyle = "dsp" *) logic signed [33:0] p_z1, p_t2, p_t3, p_zz1, p_zz2, p_zz3, p_w1, p_t0, p_t3o, p_w2, p_t1, p_t2o;
  logic signed [31:0] r_z1, r_t2, r_t3, r_zz1, r_zz2, r_zz3, r_w1, r_t0, r_t3o, r_w2, r_t1, r_t2o, r_tmp0, r_tmp1;
  logic signed [31:0] b_tmp2, b_tmp3, b_zz2m, b_zz3m, b_u0, b_u1, b_u2, b_u3;                          // A1
  logic signed [31:0] a_tmp10, a_tmp11, a_tmp12, a_tmp13, a_t0, a_t1, a_t2, a_t3;                       // A2
  logic signed [31:0] yv [0:7];
  localparam logic signed [15:0] C_0_541 = 16'sd4433,  C_0_765 = 16'sd6270,  C_1_847 = 16'sd15137;
  localparam logic signed [15:0] C_1_175 = 16'sd9633,  C_0_298 = 16'sd2446,  C_1_501 = 16'sd12299;
  localparam logic signed [15:0] C_2_053 = 16'sd16819, C_3_072 = 16'sd25172;
  localparam logic signed [15:0] CN_1_961 = -16'sd16069, CN_0_390 = -16'sd3196;
  localparam logic signed [15:0] CN_0_899 = -16'sd7373,  CN_2_562 = -16'sd20995;
  always_comb begin : g_rot
    integer i;
    for (i = 0; i < 8; i = i + 1) xe[i] = x[i];
    // stage P
    s26   = xe[2] + xe[6];
    s02   = pass1 ? x1s02 : x2s02;
    s13   = pass1 ? x1s13 : x2s13;
    s0213 = s02 + s13;
    s03   = xe[7] + xe[1];
    s12   = xe[5] + xe[3];
    e_base = pass1 ? xe[0] : x2_0p;
    s04p  = e_base + xe[4];
    s04m  = e_base - xe[4];
    // stage M
    p_z1  = pa_z1  * C_0_541;                                          // FIX_0_541196100
    p_t2  = pa_t2  * C_0_765;                                          // FIX_0_765366865
    p_t3  = pa_t3  * C_1_847;                                          // FIX_1_847759065
    p_zz1 = pa_zz1 * C_1_175;                                          //  FIX_1_175875602
    p_zz2 = pa_zz2 * CN_1_961;                                         // -FIX_1_961570560
    p_zz3 = pa_zz3 * CN_0_390;                                         // -FIX_0_390180644
    p_w1  = pa_w1  * CN_0_899;                                         // -FIX_0_899976223
    p_t0  = pa_t0  * C_0_298;                                          //  FIX_0_298631336
    p_t3o = pa_t3o * C_1_501;                                          //  FIX_1_501321110
    p_w2  = pa_w2  * CN_2_562;                                         // -FIX_2_562915447
    p_t1  = pa_t1  * C_2_053;                                          //  FIX_2_053119869
    p_t2o = pa_t2o * C_3_072;                                          //  FIX_3_072711026
    // stage B
    yv[0] = a_tmp10 + a_t3;  yv[7] = a_tmp10 - a_t3;
    yv[1] = a_tmp11 + a_t2;  yv[6] = a_tmp11 - a_t2;
    yv[2] = a_tmp12 + a_t1;  yv[5] = a_tmp12 - a_t1;
    yv[3] = a_tmp13 + a_t0;  yv[4] = a_tmp13 - a_t0;
  end
  assign w5 = g2_row[0] ? ws_rdata[0] : ws_rdata[1];
  assign w7 = p2_row[0] ? ws_rdata[0] : ws_rdata[1];
  function automatic logic signed [17:0] sx18(input logic signed [15:0] v);
    sx18 = {v[15], v[15], v};
  endfunction
  function automatic logic signed [31:0] sh13(input logic signed [17:0] v, input logic fudge);
    sh13 = {v[17], v, 2'b00, fudge, 10'd0};                           // (v << 13) + (fudge ? 1024 : 0)
  endfunction

  function automatic logic signed [15:0] sat16(input logic signed [20:0] v);
    if (v > 21'sd32767)       sat16 = 16'sd32767;
    else if (v < -21'sd32768) sat16 = 16'sh8000;
    else                      sat16 = v[15:0];
  endfunction
  function automatic logic [7:0] range_limit(input logic signed [31:0] v);
    logic [9:0] m;
    m = v[9:0];                                    // (v) & RANGE_MASK
    if (m < 10'd384)      range_limit = 8'd0;
    else if (m < 10'd640) range_limit = m[7:0] - 8'd128;
    else                  range_limit = 8'd255;
  endfunction

  logic signed [20:0] y1 [0:7];       // pass-1 results >> 11 (saturated when written), pair w1_pair per clock
  logic signed [20:0] y1e, y1o;       // rows 2p and 2p+1 of the pair being written
  logic [7:0]         y2 [0:7];       // pass-2 samples
  logic        w1_act, w1_ws;  logic [2:0] w1_col;
  logic        w2_act, w2_last, w2_lb; logic [SAW-1:0] w2_addr, w2_lba; logic [TW-1:0] w2_d;

  // ================================================================ W1: workspace writes
  // phases 2,3,0,1 -> rows (0,1), (2,3), (4,5), (6,7) of column w1_col; element (r, c) -> bank (r+c)&1.
  // Address and saturated data are registered, so the RAM writes them one clock later (phases
  // 3,0,1,2); row 0 of a finished block is read by G2 no earlier than two clocks after that.
  logic [1:0] w1_pair;
  assign w1_pair = ph - 2'd2;
  assign y1e     = y1[{w1_pair, 1'b0}];
  assign y1o     = y1[{w1_pair, 1'b1}];
  always_comb begin
    if (!w1_col[0]) begin
      ws_waddr_c[0] = {w1_ws, w1_pair, 1'b0, w1_col[2:1]}; ws_wdata_c[0] = sat16(y1e);      // row 2p   (even + even)
      ws_waddr_c[1] = {w1_ws, w1_pair, 1'b1, w1_col[2:1]}; ws_wdata_c[1] = sat16(y1o);      // row 2p+1
    end else begin
      ws_waddr_c[1] = {w1_ws, w1_pair, 1'b0, w1_col[2:1]}; ws_wdata_c[1] = sat16(y1e);
      ws_waddr_c[0] = {w1_ws, w1_pair, 1'b1, w1_col[2:1]}; ws_wdata_c[0] = sat16(y1o);
    end
  end
  always_ff @(posedge clk) begin
    ws_we <= w1_act && !rst;
    ws_waddr[0] <= ws_waddr_c[0]; ws_waddr[1] <= ws_waddr_c[1];
    ws_wdata[0] <= ws_wdata_c[0]; ws_wdata[1] <= ws_wdata_c[1];
  end

  // ================================================================ W2: sample words, phases 0 and 1
  // (line-buffer copy of row 7 in phases 2 and 3)
  always_comb begin
    case (ph)
      2'd0:    begin smp_we = w2_act;          smp_addr = w2_addr;          end
      2'd1:    begin smp_we = w2_act;          smp_addr = w2_addr + 1'b1;   end
      2'd2:    begin smp_we = w2_act && w2_lb; smp_addr = w2_lba;           end
      default: begin smp_we = w2_act && w2_lb; smp_addr = w2_lba + 1'b1;    end
    endcase
  end
  assign smp_data = ph[0] ? {y2[7], y2[6], y2[5], y2[4]} : {y2[3], y2[2], y2[1], y2[0]};
  assign smp_tag  = w2_d;
  assign blk_done = w2_act && w2_last && (ph == 2'd1);
  assign blk_tag  = w2_d;
  assign busy     = (|full) || g1_act || (|ws_pend) || (|ws_rdy) || (|ws_g1) || g2_act
                 || p1_act || q1_act || p2_act || q2_act || w1_act || ws_we || w2_act;

  // ================================================================ sequencing
  always_ff @(posedge clk) begin : g_seq
    integer i;
    if (rst) begin
      full <= '0; dirty <= 4'b1111; wp <= '0; rp <= '0; zp <= '0; zi <= '0;
      g1_act <= 1'b0; g1_col <= '0; g1_slot <= '0; g1_ws <= 1'b0; w1n <= 1'b0;
      ws_g1 <= '0; ws_pend <= '0; ws_rdy <= '0; g2n <= 1'b0;
      g2_act <= 1'b0; g2_ws <= 1'b0; g2_row <= '0; g2_addr <= '0; g2_pitch <= '0; g2_tag <= '0;
      g2_lb_en <= 1'b0; g2_lbase <= '0;
      p1_act <= 1'b0; p1_ws <= 1'b0; p1_col <= '0; q1_act <= 1'b0; q1_ws <= 1'b0; q1_col <= '0;
      p2_act <= 1'b0; p2_last <= 1'b0; p2_lb <= 1'b0; p2_row <= '0; p2_addr <= '0; p2_lba <= '0; p2_d <= '0;
      q2_act <= 1'b0; q2_last <= 1'b0; q2_lb <= 1'b0; q2_addr <= '0; q2_lba <= '0; q2_d <= '0;
      w1_act <= 1'b0; w1_ws <= 1'b0; w1_col <= '0;
      w2_act <= 1'b0; w2_last <= 1'b0; w2_lb <= 1'b0; w2_addr <= '0; w2_lba <= '0; w2_d <= '0;
      for (i = 0; i < 4; i = i + 1) desc_c[i] <= '0;
      desc_w[0] <= '0; desc_w[1] <= '0;
    end else begin
      // ---- commit / zeroing
      if (cw_commit) begin full[wp] <= 1'b1; desc_c[wp] <= cw_desc; wp <= wp + 2'd1; end
      if (zeroing && !cw_we) begin
        zi <= zi + 5'd1;
        if (zi == 5'd31) begin dirty[zp] <= 1'b0; zp <= zp + 2'd1; end
      end

      // ---- G1: decisions at the end of phase 3 (a column was read in phases 0..3)
      if (ph == 2'd3) begin
        p1_act <= g1_act; p1_col <= g1_col; p1_ws <= g1_ws;
        // a block finished one period ago: its workspace columns are written by now for row 0 of
        // pass 2 (whose element 7 is read last)
        ws_rdy <= ws_rdy | ws_pend; ws_pend <= '0;
        if (g1_act && g1_col != 3'd7) g1_col <= g1_col + 3'd1;
        else begin
          if (g1_act) begin                                    // block read completely
            full[g1_slot] <= 1'b0; dirty[g1_slot] <= 1'b1;
            ws_g1[g1_ws] <= 1'b0; ws_pend[g1_ws] <= 1'b1;
          end
          if (full[rp] && !ws_g1[w1n] && !ws_pend[w1n] && !ws_rdy[w1n]) begin   // next block, free workspace slot
            g1_act <= 1'b1; g1_col <= 3'd0; g1_slot <= rp; rp <= rp + 2'd1;
            g1_ws <= w1n; w1n <= ~w1n; ws_g1[w1n] <= 1'b1; desc_w[w1n] <= desc_c[rp];
          end else g1_act <= 1'b0;
        end
      end
      // gather: pair i of the column arrives in phase i+1
      case (ph)
        2'd1: begin x1[0] <= cb_rdata[0]; x1[1] <= cb_rdata[1]; end
        2'd2: begin x1[2] <= cb_rdata[0]; x1[3] <= cb_rdata[1]; end
        2'd3: begin x1[4] <= cb_rdata[0]; x1[5] <= cb_rdata[1]; x1s13 <= sx18(x1[1]) + sx18(cb_rdata[1]); end
        default: begin x1[6] <= cb_rdata[0]; x1[7] <= cb_rdata[1]; x1s02 <= sx18(x1[3]) + sx18(cb_rdata[1]); end
      endcase

      // ---- G2: decisions at the end of phase 1 (a row was read in phases 2,3,0,1)
      if (ph == 2'd1) begin
        p2_act <= g2_act; p2_row <= g2_row; p2_addr <= g2_addr; p2_d <= g2_tag; p2_last <= (g2_row == 3'd7);
        p2_lb <= g2_lb_en && (g2_row == 3'd7); p2_lba <= g2_lbase;
        if (g2_act && g2_row != 3'd7) begin
          g2_row <= g2_row + 3'd1; g2_addr <= g2_addr + g2_pitch;
          // rows 6 and 7 are read in the next 8 clocks, G1's first write to the slot comes later
          if (g2_row == 3'd5) ws_rdy[g2_ws] <= 1'b0;
        end else if (ws_rdy[g2n] && p2_ok) begin
          g2_act <= 1'b1; g2_row <= 3'd0; g2_ws <= g2n; g2n <= ~g2n;
          g2_addr <= p2_base; g2_pitch <= p2_pitch; g2_tag <= p2_tag;
          g2_lb_en <= p2_lb_en; g2_lbase <= p2_lbase;
        end else g2_act <= 1'b0;
      end
      // gather: pairs 0..3 of the row arrive in phases 3, 0, 1, 2; columns 2i / 2i+1 swap banks on
      // odd rows (pair 3 belongs to the row that G2 has just left: p2_row)
      case (ph)
        2'd3: begin
          x2[0] <= g2_row[0] ? ws_rdata[1] : ws_rdata[0]; x2[1] <= g2_row[0] ? ws_rdata[0] : ws_rdata[1];
          x2_0p <= sx18(g2_row[0] ? ws_rdata[1] : ws_rdata[0]) + 18'sd16400;
        end
        2'd0: begin x2[2] <= g2_row[0] ? ws_rdata[1] : ws_rdata[0]; x2[3] <= g2_row[0] ? ws_rdata[0] : ws_rdata[1]; end
        2'd1: begin x2[4] <= g2_row[0] ? ws_rdata[1] : ws_rdata[0]; x2[5] <= w5; end
        default: begin
          x2[6] <= p2_row[0] ? ws_rdata[1] : ws_rdata[0]; x2[7] <= w7;
          x2s13 <= sx18(x2[1]) + sx18(x2[5]);             // (both registered; used in phase 3)
          x2s02 <= sx18(x2[3]) + sx18(w7);
        end
      endcase

      // ---- stage P (phase 1: column of pass 1, phase 3: row of pass 2)
      // The multiplier operands and products are loaded every clock (each value is consumed in the
      // clock right after it is written), so they fit the DSP blocks' input and output registers,
      // which share one clock enable.
      pa_z1 <= s26;    pa_t2 <= xe[2];  pa_t3 <= xe[6];
      pa_zz1 <= s0213; pa_zz2 <= s02;   pa_zz3 <= s13;
      pa_w1 <= s03;    pa_t0 <= xe[7];  pa_t3o <= xe[1];
      pa_w2 <= s12;    pa_t1 <= xe[5];  pa_t2o <= xe[3];
      if (ph[0]) begin pa_e0 <= s04p; pa_e1 <= s04m; pa_pass1 <= pass1; end
      if (ph == 2'd1) begin q1_act <= p1_act; q1_col <= p1_col; q1_ws <= p1_ws; end
      if (ph == 2'd3) begin
        q2_act <= p2_act; q2_last <= p2_last; q2_lb <= p2_lb; q2_addr <= p2_addr; q2_lba <= p2_lba; q2_d <= p2_d;
      end
      // ---- stage M (phases 2, 0)
      r_z1 <= p_z1[31:0]; r_t2 <= p_t2[31:0]; r_t3 <= p_t3[31:0];
      r_zz1 <= p_zz1[31:0]; r_zz2 <= p_zz2[31:0]; r_zz3 <= p_zz3[31:0];
      r_w1 <= p_w1[31:0]; r_t0 <= p_t0[31:0]; r_t3o <= p_t3o[31:0];
      r_w2 <= p_w2[31:0]; r_t1 <= p_t1[31:0]; r_t2o <= p_t2o[31:0];
      if (!ph[0]) begin r_tmp0 <= sh13(pa_e0, pa_pass1); r_tmp1 <= sh13(pa_e1, pa_pass1); end   // (read two clocks later)
      // ---- stage A1 (phases 3, 1)
      if (ph[0]) begin
        b_tmp2 <= r_z1 + r_t2;    b_tmp3 <= r_z1 - r_t3;
        b_zz2m <= r_zz2 + r_zz1;  b_zz3m <= r_zz3 + r_zz1;
        b_u0 <= r_t0 + r_w1;      b_u3 <= r_t3o + r_w1;
        b_u1 <= r_t1 + r_w2;      b_u2 <= r_t2o + r_w2;
      end
      // ---- stage A2 (phases 0, 2); r_tmp0/1 of this vector are only replaced at the end of this clock
      if (!ph[0]) begin
        a_tmp10 <= r_tmp0 + b_tmp2;  a_tmp13 <= r_tmp0 - b_tmp2;
        a_tmp11 <= r_tmp1 + b_tmp3;  a_tmp12 <= r_tmp1 - b_tmp3;
        a_t0 <= b_u0 + b_zz2m;       a_t3 <= b_u3 + b_zz3m;
        a_t1 <= b_u1 + b_zz3m;       a_t2 <= b_u2 + b_zz2m;
      end
      // ---- stage B: phase 1 -> pass-1 values for W1, phase 3 -> pass-2 samples for W2
      if (ph == 2'd1) begin
        for (i = 0; i < 8; i = i + 1) y1[i] <= yv[i][31:11];        // >>> (CONST_BITS - PASS1_BITS)
        w1_act <= q1_act; w1_col <= q1_col; w1_ws <= q1_ws;
      end
      if (ph == 2'd3) begin
        for (i = 0; i < 8; i = i + 1) y2[i] <= range_limit(yv[i] >>> (CONST_BITS + PASS1_BITS + 3));
        w2_act <= q2_act; w2_last <= q2_last; w2_addr <= q2_addr; w2_d <= q2_d; w2_lb <= q2_lb; w2_lba <= q2_lba;
      end
    end
  end
endmodule
