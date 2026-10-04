// jpeg_mcuout_wide.sv - MCU-order output stage of the WIDE build (FAST = 2): four pixels per clock.
//
// Same job as jpeg_mcuout, four pixels at a time.  The MCU buffer is one RAM per component
// (64-bit words: 8 samples, sample i in bits 8i+7..8i, one block row as jpeg_idct_wide writes it)
// holding NBUF = 3 MCUs, so the IDCT can fill two MCUs while this module emits a third.  Inside a
// buffer, component c is stored as a plane of 8*Hc x 8*Vc samples, pitch Hc words; buffer b starts
// at word 32*b.  Every clock one word is read from each component RAM: four pixels of an MCU line
// start at a multiple of 4, so their samples (full size or horizontally subsampled, by sample
// replication, T.81 A.1.1, libjpeg -nosmooth) lie in one word.  Each beat carries pixels x .. x+n-1 of one line
// (n = 4, fewer only at the right edge of the image); pixel i is in bits 8i+7..8i of px_c0/1/2.
// Colour conversion, formats and pipeline are those of jpeg_mcuout, once per pixel: libjpeg's
// ycc_rgb_convert (jdcolor.c) with tables Cr -> {Cr_r, Cr_g}, Cb -> {Cb_b, Cb_g} read in the clock
// the samples are picked out of the words, the G terms added and descaled in the next stage, Y added
// and clamped in the last one.  Only the part of the MCU inside the image is emitted.
// Based in part on the work of the Independent JPEG Group: the arithmetic reproduces libjpeg /
// libjpeg-turbo so that the output is bit-identical to them (see NOTICE.md).
module jpeg_mcuout_wide #(
  parameter bit CC_TURBO = 1'b0,
  parameter bit RGB_OUT  = 1'b1
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        start,          // pulse: emit the MCU in buffer `buf_i`
  input  logic [1:0]  buf_i,
  input  logic [15:0] x0,             // image position of the MCU
  input  logic [15:0] y0,
  input  logic [4:0]  width,          // pixels per line inside the image (1..16)
  input  logic [4:0]  nlines,         // lines inside the image (1..16)
  output logic        done,           // pulse: last beat handed to the colour stages
  output logic        idle,           // nothing in flight and the output register empty
  output logic        ready,          // a new MCU may be started (the previous one's last address is out)
  // frame geometry
  input  logic [15:0] img_w,
  input  logic        gray,
  input  logic [1:0]  fmt,
  input  logic [2:0]  uh,             // component c subsampled horizontally (Hc < Hmax)
  input  logic [2:0]  uv,             // ... vertically
  input  logic [2:0]  h2,             // component c has Hc = 2 (plane pitch 2 words, else 1)
  // component RAM read ports (registered read, 1 clock)
  output logic [6:0]  raddr0,
  output logic [6:0]  raddr1,
  output logic [6:0]  raddr2,
  input  logic [63:0] rdata0,
  input  logic [63:0] rdata1,
  input  logic [63:0] rdata2,
  // pixels: pixel i of the beat in bits 8i+7..8i, at (px_x + i, px_y), i < px_n
  output logic        px_valid,
  input  logic        px_ready,
  output logic [15:0] px_x,
  output logic [15:0] px_y,
  output logic [2:0]  px_n,
  output logic [31:0] px_c0,
  output logic [31:0] px_c1,
  output logic [31:0] px_c2,
  output logic        px_sof,
  output logic        px_eol
);
  import jpeg_pkg::*;

  // ---------------------------------------------------------------- address stage (A)
  logic        a_busy;
  logic [1:0]  a_buf;
  logic [3:0]  ax, ay;                 // position inside the MCU (ax: multiple of 4)
  logic [3:0]  wm1, lm1;               // width-1, nlines-1
  logic [15:0] ax0, ay0;
  function automatic logic [6:0] waddr(input logic [1:0] b, input logic [3:0] x, input logic [3:0] y,
                                       input logic sh, input logic sv, input logic ph2);
    logic [3:0] xc, yc;
    logic [4:0] row;
    xc  = sh ? {1'b0, x[3:1]} : x;
    yc  = sv ? {1'b0, y[3:1]} : y;
    row = ph2 ? {yc, 1'b0} : {1'b0, yc};           // yc * pitch (2 or 1 words)
    waddr = {b, row + {4'd0, xc[3]}};
  endfunction
  // ---------------------------------------------------------------- data stage (D): RAM output
  // Invariant: while d_valid, the RAM outputs hold the words of beat (d_ax, d_ay).  When D cannot
  // hand its beat on, the same addresses are read again so the outputs stay put.
  logic        d_valid, d_last, d_sof, d_eol;
  logic [1:0]  d_buf;
  logic [3:0]  d_ax, d_ay;
  logic [2:0]  d_n;
  logic [15:0] d_x, d_y;
  logic [3:0]  sx, sy;                 // beat whose words are read this clock
  logic [1:0]  s_buf;
  // ---------------------------------------------------------------- value stage (V)
  logic        v_valid, v_conv, v_sof, v_eol;
  logic [2:0]  v_n;
  logic [15:0] v_x, v_y;
  logic [7:0]  v_a [0:3], v_b [0:3], v_c [0:3];
  logic        en, d_take;
  assign en     = ~px_valid | px_ready;        // the chain V -> C2 -> O moves on
  assign d_take = d_valid & en;
  // the address stage issues the next beat when D is free or handing its beat on this clock
  logic        a_adv;
  assign a_adv  = a_busy & (~d_valid | d_take);
  assign sx     = (d_valid & ~d_take) ? d_ax : ax;
  assign sy     = (d_valid & ~d_take) ? d_ay : ay;
  assign s_buf  = (d_valid & ~d_take) ? d_buf : a_buf;       // (the next MCU may already have started)
  assign raddr0 = waddr(s_buf, sx, sy, uh[0], uv[0], h2[0]);
  assign raddr1 = waddr(s_buf, sx, sy, uh[1], uv[1], h2[1]);
  assign raddr2 = waddr(s_buf, sx, sy, uh[2], uv[2], h2[2]);

  function automatic logic [7:0] lane(input logic [63:0] w, input logic [2:0] b);
    lane = w[8*b +: 8];
  endfunction
  // byte lane of pixel i of the beat at x (a multiple of 4) for a component subsampled or not
  function automatic logic [2:0] blane(input logic [3:0] x, input logic [1:0] i, input logic sh);
    logic [3:0] xi;
    xi = x + {2'b00, i};
    blane = sh ? xi[3:1] : xi[2:0];
  endfunction

  logic luma_only;
  assign luma_only = gray | (fmt == FMT_Y);

  // ---------------------------------------------------------------- colour conversion stages
  // tables (jdcolor.c build_ycc_rgb_table, SCALEBITS = 16):
  //   Cr_r = (FIX(1.402) x + ONE_HALF) >> 16          Cr_g = -FIX(0.71414..) x
  //   Cb_b = (FIX(1.772) x + ONE_HALF) >> 16          Cb_g = -FIX(0.34414 | 0.344136286) x + ONE_HALF
  //   x = value - 128;  G = Y + ((Cb_g + Cr_g) >> 16)
  logic [33:0] crtab [0:255];                        // {Cr_r[9:0], Cr_g[23:0]}
  logic [32:0] cbtab [0:255];                        // {Cb_b[9:0], Cb_g[22:0]}
  integer ti, tr_, tg_, tb_, tgb_;
  initial begin
    for (ti = 0; ti < 256; ti = ti + 1) begin
      tr_  = (91881 * (ti - 128) + 32768) >>> 16;
      tg_  = -46802 * (ti - 128);
      tb_  = (116130 * (ti - 128) + 32768) >>> 16;
      tgb_ = (CC_TURBO ? -22554 : -22553) * (ti - 128) + 32768;
      crtab[ti] = {tr_[9:0], tg_[23:0]};
      cbtab[ti] = {tb_[9:0], tgb_[22:0]};
    end
  end
  function automatic logic [7:0] clamp8(input logic signed [9:0] v);
    if (v < 10'sd0)        clamp8 = 8'd0;
    else if (v > 10'sd255) clamp8 = 8'd255;
    else                   clamp8 = v[7:0];
  endfunction

  // G term of a pixel: (Cb_g + Cr_g) >> 16
  function automatic logic signed [9:0] gterm(input logic [32:0] cb, input logic [33:0] cr);
    logic signed [24:0] t;
    t = ($signed({{2{cb[22]}}, cb[22:0]}) + $signed({cr[23], cr[23:0]})) >>> 16;
    gterm = t[9:0];
  endfunction

  // ---------------------------------------------------------------- the four pixels of a beat
  // One process per pixel (a generate loop) holds that pixel's byte lanes, samples, table entries,
  // colour terms and output bytes; the main process below only moves the beat's control (valid,
  // x, y, n, sof, eol).  Vivado 2026.1's xsim mis-evaluates array elements indexed by a procedural
  // loop variable inside other array indexes (tab[idx[k]] read as tab[k]), which made the colour
  // conversion wrong there; constant (genvar) indexes avoid it.  Same logic as one loop.
  logic        c2_valid, c2_conv, c2_sof, c2_eol;
  logic [2:0]  c2_n;
  logic [15:0] c2_x, c2_y;
  logic [7:0]  o_c0 [0:3], o_c1 [0:3], o_c2 [0:3];   // output bytes per pixel
  assign px_c0 = {o_c0[3], o_c0[2], o_c0[1], o_c0[0]};
  assign px_c1 = {o_c1[3], o_c1[2], o_c1[1], o_c1[0]};
  assign px_c2 = {o_c2[3], o_c2[2], o_c2[1], o_c2[0]};
  genvar gp;
  generate
    for (gp = 0; gp < 4; gp = gp + 1) begin : g_pix
      logic [2:0]  b0, b1, b2;                       // byte lanes (D stage)
      logic [33:0] crq;                              // table entries (V stage)
      logic [32:0] cbq;
      logic [7:0]  c2a, c2b, c2c;                    // samples (C2 stage)
      logic signed [9:0] c2sr, c2sg, c2sb;           // colour terms (C2 stage)
      always_ff @(posedge clk) begin
        if (rst) begin
          o_c0[gp] <= '0; o_c1[gp] <= '0; o_c2[gp] <= '0;
        end else begin
          if (en) begin                              // C2 -> O and V -> C2
            o_c0[gp] <= (RGB_OUT && c2_conv) ? clamp8($signed({2'b00, c2a}) + c2sr) : c2a;
            o_c1[gp] <= (RGB_OUT && c2_conv) ? clamp8($signed({2'b00, c2a}) + c2sg) : c2b;
            o_c2[gp] <= (RGB_OUT && c2_conv) ? clamp8($signed({2'b00, c2a}) + c2sb) : c2c;
            c2a <= v_a[gp]; c2b <= v_b[gp]; c2c <= v_c[gp];
            c2sr <= crq[33:24]; c2sg <= gterm(cbq, crq); c2sb <= cbq[32:23];
          end
          if (d_take) begin                          // D -> V: samples out of the words, table entries
            crq <= crtab[lane(rdata2, b2)]; cbq <= cbtab[lane(rdata1, b1)];
            v_a[gp] <= lane(rdata0, b0);
            if (luma_only) begin
              v_b[gp] <= (RGB_OUT && gray && fmt == FMT_RGB) ? lane(rdata0, b0) : 8'd128;
              v_c[gp] <= (RGB_OUT && gray && fmt == FMT_RGB) ? lane(rdata0, b0) : 8'd128;
            end else begin
              v_b[gp] <= lane(rdata1, b1); v_c[gp] <= lane(rdata2, b2);
            end
          end
          if (a_adv) begin                           // A -> D: byte lanes of this pixel
            b0 <= blane(ax, gp[1:0], uh[0]); b1 <= blane(ax, gp[1:0], uh[1]); b2 <= blane(ax, gp[1:0], uh[2]);
          end
        end
      end
    end
  endgenerate

  assign idle  = ~a_busy & ~d_valid & ~v_valid & ~c2_valid & ~px_valid;
  assign ready = ~a_busy;

  logic [15:0] cur_x, cur_y;
  logic [3:0]  rem;                                 // pixels left on this line - 1
  logic [2:0]  cur_n;
  assign cur_x = ax0 + {12'd0, ax};
  assign cur_y = ay0 + {12'd0, ay};
  assign rem   = wm1 - ax;
  assign cur_n = (rem[3:2] != 2'd0) ? 3'd4 : {1'b0, rem[1:0]} + 3'd1;

  always_ff @(posedge clk) begin : p_main
    done <= 1'b0;
    if (rst) begin
      a_busy <= 1'b0; a_buf <= '0; ax <= '0; ay <= '0; wm1 <= '0; lm1 <= '0; ax0 <= '0; ay0 <= '0;
      d_valid <= 1'b0; d_last <= 1'b0; d_sof <= 1'b0; d_eol <= 1'b0; d_ax <= '0; d_ay <= '0; d_buf <= '0; d_n <= '0; d_x <= '0; d_y <= '0;
      v_valid <= 1'b0; v_conv <= 1'b0; v_sof <= 1'b0; v_eol <= 1'b0; v_n <= '0; v_x <= '0; v_y <= '0;
      c2_valid <= 1'b0; c2_conv <= 1'b0; c2_sof <= 1'b0; c2_eol <= 1'b0; c2_n <= '0; c2_x <= '0; c2_y <= '0;
      px_valid <= 1'b0; px_x <= '0; px_y <= '0; px_n <= '0; px_sof <= 1'b0; px_eol <= 1'b0;
    end else begin
      // ---- V -> C2 -> O (bubbles move along too)
      if (en) begin
        px_valid <= c2_valid; px_x <= c2_x; px_y <= c2_y; px_n <= c2_n; px_sof <= c2_sof; px_eol <= c2_eol;
        c2_valid <= v_valid; c2_conv <= v_conv; c2_sof <= v_sof; c2_eol <= v_eol; c2_n <= v_n; c2_x <= v_x; c2_y <= v_y;
        v_valid <= 1'b0;
      end else if (px_valid & px_ready) px_valid <= 1'b0;
      // ---- V stage (the samples and table entries: per pixel, in g_pix)
      if (d_take) begin
        v_valid <= 1'b1; v_x <= d_x; v_y <= d_y; v_n <= d_n; v_sof <= d_sof; v_eol <= d_eol;
        v_conv <= !luma_only && RGB_OUT && (fmt == FMT_RGB);
        if (d_last) done <= 1'b1;
        d_valid <= 1'b0;
      end
      // ---- A stage: this clock's addresses are being read; the data is valid next clock
      if (a_adv) begin
        d_valid <= 1'b1; d_x <= cur_x; d_y <= cur_y; d_ax <= ax; d_ay <= ay; d_buf <= a_buf; d_n <= cur_n;
        d_sof <= (cur_x == 16'd0) && (cur_y == 16'd0);
        d_eol <= (cur_x + {13'd0, cur_n} == img_w);
        d_last <= (ax[3:2] == wm1[3:2]) && (ay == lm1);
        if (ax[3:2] == wm1[3:2]) begin
          ax <= '0;
          if (ay == lm1) a_busy <= 1'b0; else ay <= ay + 4'd1;
        end else ax <= ax + 4'd4;
      end
      if (start) begin
        a_busy <= 1'b1; a_buf <= buf_i; ax <= '0; ay <= '0;
        wm1 <= width[3:0] - 4'd1; lm1 <= nlines[3:0] - 4'd1; ax0 <= x0; ay0 <= y0;
      end
    end
  end
endmodule
