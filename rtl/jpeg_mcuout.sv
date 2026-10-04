// jpeg_mcuout.sv - MCU-order output stage of the FAST build: one pixel per clock.
//
// The MCU buffer of the FAST build is one RAM per component (32-bit words, 4 samples each), each
// with two halves, so the IDCT fills MCU m+1 while this module emits MCU m.  Inside a half,
// component c is stored as a plane of 8*Hc x 8*Vc samples, pitch 2*Hc words.  Every clock one
// word is read from each component RAM (a new pixel every clock); chroma is upsampled by sample
// replication (T.81 A.1.1, libjpeg -nosmooth), then the pixel is formatted like jpeg_pixgen does
// (RGB, YCbCr, or Y only).  Only the part of the MCU inside the image is emitted.
// The YCbCr->RGB conversion is done like libjpeg's ycc_rgb_convert (jdcolor.c): per chroma value
// a precomputed table entry - Cr -> {Cr_r, Cr_g}, Cb -> {Cb_b, Cb_g} - read from block RAM (no
// multipliers) in the same clock as the samples are picked out of the words, the G terms added
// and descaled in the next stage, Y added and clamped in the last one.  The stages behind the RAM
// read advance together whenever the output register is free.
// Based in part on the work of the Independent JPEG Group: the arithmetic reproduces libjpeg /
// libjpeg-turbo so that the output is bit-identical to them (see NOTICE.md).
module jpeg_mcuout #(
  parameter bit CC_TURBO = 1'b0,
  parameter bit RGB_OUT  = 1'b1
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        start,          // pulse: emit the MCU in half `half`
  input  logic        half,
  input  logic [15:0] x0,             // image position of the MCU
  input  logic [15:0] y0,
  input  logic [4:0]  width,          // pixels per line inside the image (1..16)
  input  logic [4:0]  nlines,         // lines inside the image (1..16)
  output logic        done,           // pulse: last pixel handed to the output register
  output logic        idle,           // nothing in flight and the output register empty
  output logic        ready,          // a new MCU may be started (the previous one's last address is out)
  // frame geometry
  input  logic [15:0] img_w,
  input  logic        gray,
  input  logic [1:0]  fmt,
  input  logic [2:0]  uh,             // component c subsampled horizontally (Hc < Hmax)
  input  logic [2:0]  uv,             // ... vertically
  input  logic [2:0]  h2,             // component c has Hc = 2 (plane pitch 4 words, else 2)
  // component RAM read ports (registered read, 1 clock)
  output logic [6:0]  raddr0,
  output logic [6:0]  raddr1,
  output logic [6:0]  raddr2,
  input  logic [31:0] rdata0,
  input  logic [31:0] rdata1,
  input  logic [31:0] rdata2,
  // pixels
  output logic        px_valid,
  input  logic        px_ready,
  output logic [15:0] px_x,
  output logic [15:0] px_y,
  output logic [7:0]  px_c0,
  output logic [7:0]  px_c1,
  output logic [7:0]  px_c2,
  output logic        px_sof,
  output logic        px_eol
);
  import jpeg_pkg::*;

  // ---------------------------------------------------------------- address stage (A)
  logic        a_busy, a_half;
  logic [3:0]  ax, ay;                 // position inside the MCU
  logic [3:0]  wm1, lm1;               // width-1, nlines-1
  logic [15:0] ax0, ay0;
  function automatic logic [6:0] waddr(input logic hf, input logic [3:0] x, input logic [3:0] y,
                                       input logic sh, input logic sv, input logic ph2);
    logic [3:0] xc, yc;
    logic [5:0] row;
    xc  = sh ? {1'b0, x[3:1]} : x;
    yc  = sv ? {1'b0, y[3:1]} : y;
    row = ph2 ? {yc, 2'b00} : {1'b0, yc, 1'b0};    // yc * pitch (4 or 2 words)
    waddr = {hf, row + {4'd0, xc[3:2]}};
  endfunction
  // ---------------------------------------------------------------- data stage (D): RAM output
  // Invariant: while d_valid, the RAM outputs hold the words of pixel (d_ax, d_ay).  When D cannot
  // hand its pixel on, the same addresses are read again so the outputs stay put.
  logic        d_valid, d_last, d_sof, d_eol, d_half;
  logic [3:0]  d_ax, d_ay;
  logic [1:0]  d_b0, d_b1, d_b2;       // byte lane per component
  logic [15:0] d_x, d_y;
  logic [3:0]  sx, sy;                 // pixel whose words are read this clock
  logic        s_half;
  // ---------------------------------------------------------------- value stage (V)
  logic        v_valid, v_conv, v_sof, v_eol;
  logic [15:0] v_x, v_y;
  logic [7:0]  v_a, v_b, v_c;
  logic        en, d_take;
  assign en     = ~px_valid | px_ready;        // the chain V -> C2 -> O moves on
  assign d_take = d_valid & en;
  // the address stage issues the next pixel when D is free or handing its pixel on this clock
  logic        a_adv;
  assign a_adv  = a_busy & (~d_valid | d_take);
  assign sx     = (d_valid & ~d_take) ? d_ax : ax;
  assign sy     = (d_valid & ~d_take) ? d_ay : ay;
  assign s_half = (d_valid & ~d_take) ? d_half : a_half;     // (the next MCU may already have started)
  assign raddr0 = waddr(s_half, sx, sy, uh[0], uv[0], h2[0]);
  assign raddr1 = waddr(s_half, sx, sy, uh[1], uv[1], h2[1]);
  assign raddr2 = waddr(s_half, sx, sy, uh[2], uv[2], h2[2]);

  function automatic logic [7:0] lane(input logic [31:0] w, input logic [1:0] b);
    lane = w[8*b +: 8];
  endfunction
  function automatic logic [1:0] blane(input logic [3:0] x, input logic sh);
    blane = sh ? x[2:1] : x[1:0];
  endfunction

  logic luma_only;
  assign luma_only = gray | (fmt == FMT_Y);

  // ---------------------------------------------------------------- colour conversion stages
  // tables (jdcolor.c build_ycc_rgb_table, SCALEBITS = 16):
  //   Cr_r = (FIX(1.402) x + ONE_HALF) >> 16          Cr_g = -FIX(0.71414..) x
  //   Cb_b = (FIX(1.772) x + ONE_HALF) >> 16          Cb_g = -FIX(0.34414 | 0.344136286) x + ONE_HALF
  //   x = value - 128;  G = Y + ((Cb_g + Cr_g) >> 16)
  (* romstyle = "M4K" *) logic [33:0] crtab [0:255];  // {Cr_r[9:0], Cr_g[23:0]}
  (* romstyle = "M4K" *) logic [32:0] cbtab [0:255];  // {Cb_b[9:0], Cb_g[22:0]}
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
  logic [33:0] crq;                                  // table entries of the pixel in V
  logic [32:0] cbq;
  logic        c2_valid, c2_conv, c2_sof, c2_eol;
  logic [15:0] c2_x, c2_y;
  logic [7:0]  c2_a, c2_b, c2_c;
  logic signed [24:0] t_g;
  logic signed [9:0]  c2_sr, c2_sg, c2_sb;
  logic signed [9:0]  r_raw, g_raw, b_raw;
  assign t_g   = ($signed({{2{cbq[22]}}, cbq[22:0]}) + $signed({crq[23], crq[23:0]})) >>> 16;
  always_ff @(posedge clk) begin
    if (d_take) begin crq <= crtab[lane(rdata2, d_b2)]; cbq <= cbtab[lane(rdata1, d_b1)]; end
  end
  assign r_raw = $signed({2'b00, c2_a}) + c2_sr;
  assign g_raw = $signed({2'b00, c2_a}) + c2_sg;
  assign b_raw = $signed({2'b00, c2_a}) + c2_sb;
  function automatic logic [7:0] clamp8(input logic signed [9:0] v);
    if (v < 10'sd0)        clamp8 = 8'd0;
    else if (v > 10'sd255) clamp8 = 8'd255;
    else                   clamp8 = v[7:0];
  endfunction

  assign idle  = ~a_busy & ~d_valid & ~v_valid & ~c2_valid & ~px_valid;
  assign ready = ~a_busy;

  logic [15:0] cur_x, cur_y;
  assign cur_x = ax0 + {12'd0, ax};
  assign cur_y = ay0 + {12'd0, ay};

  always_ff @(posedge clk) begin
    done <= 1'b0;
    if (rst) begin
      a_busy <= 1'b0; a_half <= 1'b0; ax <= '0; ay <= '0; wm1 <= '0; lm1 <= '0; ax0 <= '0; ay0 <= '0;
      d_valid <= 1'b0; d_last <= 1'b0; d_sof <= 1'b0; d_eol <= 1'b0; d_ax <= '0; d_ay <= '0; d_half <= 1'b0; d_b0 <= '0; d_b1 <= '0; d_b2 <= '0; d_x <= '0; d_y <= '0;
      v_valid <= 1'b0; v_conv <= 1'b0; v_sof <= 1'b0; v_eol <= 1'b0; v_x <= '0; v_y <= '0; v_a <= '0; v_b <= '0; v_c <= '0;

      c2_valid <= 1'b0; c2_conv <= 1'b0; c2_sof <= 1'b0; c2_eol <= 1'b0; c2_x <= '0; c2_y <= '0; c2_a <= '0; c2_b <= '0; c2_c <= '0;
      c2_sr <= '0; c2_sg <= '0; c2_sb <= '0;
      px_valid <= 1'b0; px_x <= '0; px_y <= '0; px_c0 <= '0; px_c1 <= '0; px_c2 <= '0; px_sof <= 1'b0; px_eol <= 1'b0;
    end else begin
      // ---- V -> C2 -> O (bubbles move along too)
      if (en) begin
        px_valid <= c2_valid; px_x <= c2_x; px_y <= c2_y; px_sof <= c2_sof; px_eol <= c2_eol;
        px_c0 <= (RGB_OUT && c2_conv) ? clamp8(r_raw) : c2_a;
        px_c1 <= (RGB_OUT && c2_conv) ? clamp8(g_raw) : c2_b;
        px_c2 <= (RGB_OUT && c2_conv) ? clamp8(b_raw) : c2_c;
        c2_valid <= v_valid; c2_conv <= v_conv; c2_sof <= v_sof; c2_eol <= v_eol; c2_x <= v_x; c2_y <= v_y;
        c2_a <= v_a; c2_b <= v_b; c2_c <= v_c;
        c2_sr <= crq[33:24]; c2_sg <= t_g[9:0]; c2_sb <= cbq[32:23];
        v_valid <= 1'b0;
      end else if (px_valid & px_ready) px_valid <= 1'b0;
      // ---- V stage: pick the samples out of the words
      if (d_take) begin
        v_valid <= 1'b1; v_x <= d_x; v_y <= d_y; v_sof <= d_sof; v_eol <= d_eol;
        v_a <= lane(rdata0, d_b0);
        if (luma_only) begin
          v_b <= (RGB_OUT && gray && fmt == FMT_RGB) ? lane(rdata0, d_b0) : 8'd128;
          v_c <= (RGB_OUT && gray && fmt == FMT_RGB) ? lane(rdata0, d_b0) : 8'd128;
          v_conv <= 1'b0;
        end else begin
          v_b <= lane(rdata1, d_b1); v_c <= lane(rdata2, d_b2);
          v_conv <= RGB_OUT && (fmt == FMT_RGB);
        end
        if (d_last) done <= 1'b1;
        d_valid <= 1'b0;
      end
      // ---- A stage: this clock's addresses are being read; the data is valid next clock
      if (a_adv) begin
        d_valid <= 1'b1; d_x <= cur_x; d_y <= cur_y; d_ax <= ax; d_ay <= ay; d_half <= a_half;
        d_sof <= (cur_x == 16'd0) && (cur_y == 16'd0);
        d_eol <= (cur_x == img_w - 16'd1);
        d_b0 <= blane(ax, uh[0]); d_b1 <= blane(ax, uh[1]); d_b2 <= blane(ax, uh[2]);
        d_last <= (ax == wm1) && (ay == lm1);
        if (ax == wm1) begin
          ax <= '0;
          if (ay == lm1) a_busy <= 1'b0; else ay <= ay + 4'd1;
        end else ax <= ax + 4'd1;
      end
      if (start) begin
        a_busy <= 1'b1; a_half <= half; ax <= '0; ay <= '0;
        wm1 <= width[3:0] - 4'd1; lm1 <= nlines[3:0] - 4'd1; ax0 <= x0; ay0 <= y0;
      end
    end
  end
endmodule
