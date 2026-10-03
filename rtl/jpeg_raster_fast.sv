// jpeg_raster_fast.sv - raster-order output stage of the FAST build (RASTER_OUT = 1): one pixel
// per clock for 4:2:0, 4:2:2, 4:4:4 and grey, with or without libjpeg-turbo's fancy upsampling.
//
// Each component has its own row-buffer RAM (32-bit words, 4 samples each) holding the plane of
// one MCU row (two planes when the image is narrow enough for ping-pong buffering) and line
// buffers (LB) with the last sample row of earlier MCU rows, which the IDCT writes itself.
// The upsampling arithmetic is the one of jpeg_raster: per component a stream of column sums
// cs = 3*near + far (vertical filter) or 4*near, and
//     out = (3*cs[i] + cs[neighbour] + bias) >> 4
// (edges replicated at the true component size; see model/jpeg_golden.py upsample_plane).
//
// Per component a fetcher reads the columns of the current line from its RAM, one word per clock
// (near and far row alternately when the vertical filter is on), and pushes the column sums into
// a 3-entry FIFO; the pixel stage pops them as the upsampling pattern needs (every pixel, every
// second pixel, or a sliding window of three for the horizontal filter).  A component needs at
// most one read per pixel except for the vertical-only filter (h1v2, 4:4:0 chroma: two).
//
// Commands (see jpeg_dec_fast): CMD_LINES emits lines 0..nlines-1 of the MCU row in the planes at
// pbase (line 0 takes its row above from the LB at lbase, or replicates it in the first MCU row);
// CMD_DEFER emits the deferred last line of the previous MCU row: near rows from the LB at lbase,
// row below = row 0 of the planes at pbase.
// Based in part on the work of the Independent JPEG Group: the arithmetic reproduces libjpeg /
// libjpeg-turbo so that the output is bit-identical to them (see NOTICE.md).
module jpeg_raster_fast #(
  parameter int AW       = 12,        // word address width of the component RAMs
  parameter bit FANCY    = 1'b0,
  parameter bit CC_TURBO = 1'b0,
  parameter bit RGB_OUT  = 1'b1
) (
  input  logic            clk,
  input  logic            rst,
  // command
  input  logic            start,
  input  logic [1:0]      mode,       // CMD_LINES / CMD_DEFER
  input  logic [4:0]      nlines,     // CMD_LINES: local lines 0 .. nlines-1
  input  logic [15:0]     y0,         // image row of the first line
  input  logic            first_row,  // CMD_LINES: MCU row 0 (no row above the image)
  input  logic            lastrow,    // CMD_LINES: last MCU row of the image
  input  logic [3*AW-1:0] pbase,      // per component: plane of the MCU row (word address)
  input  logic [3*AW-1:0] lbase,      // per component: line buffer with the previous MCU row's last row
  output logic            done,       // pulse: last pixel handed on
  output logic            idle,       // no command running and the output pipeline empty
  // frame geometry
  input  logic [15:0]     img_w,
  input  logic [15:0]     img_h,
  input  logic [1:0]      nproc,      // components read: 1 (grey image or FMT_Y) or 3
  input  logic            gray,
  input  logic [1:0]      fmt,
  input  logic [2:0]      uh,         // component c subsampled horizontally (Hc < Hmax)
  input  logic [2:0]      uv,         // ... vertically
  input  logic [2:0]      hf,         // horizontal triangle filter active for component c
  input  logic [2:0]      vf,         // vertical triangle filter active for component c
  input  logic [3*AW-1:0] pw,         // per component: words per plane row
  // component RAM read ports (registered read, 1 clock)
  output logic [3*AW-1:0] raddr,
  input  logic [95:0]     rdata,
  // pixels
  output logic            px_valid,
  input  logic            px_ready,
  output logic [15:0]     px_x,
  output logic [15:0]     px_y,
  output logic [7:0]      px_c0,
  output logic [7:0]      px_c1,
  output logic [7:0]      px_c2,
  output logic            px_sof,
  output logic            px_eol
);
  import jpeg_pkg::*;

  function automatic logic [AW-1:0] gA(input logic [3*AW-1:0] v, input integer c);
    gA = v[c*AW +: AW];
  endfunction

  // ---------------------------------------------------------------- command / line state
  typedef enum logic [1:0] { R_IDLE, R_LINE, R_PRIME, R_PIX } rstate_t;
  rstate_t state;
  logic          defer_r, first_r, lastrow_r;
  logic [4:0]    lines_left;
  logic [3:0]    l;                    // local line inside the MCU row
  logic [15:0]   x, y, wm1;
  logic          vline;                // lower output row of a vertical pair
  logic [2:0]    lastcr;               // ((H-1)/2) mod 8: last row of a vertically subsampled component
  logic [AW-1:0] nrow [0:2];           // near row of component c for the current line
  logic [AW-1:0] lbr  [0:2];           // line buffer of the command
  logic [14:0]   cwl_m1;               // columns per line - 1 of the horizontally subsampled components

  // ---------------------------------------------------------------- fetchers
  logic [14:0]   fj   [0:2];           // next column to fetch
  logic          fdone [0:2];          // all columns of the line fetched
  logic          fph  [0:2];           // 1: the far sample of column fj is next (vertical filter)
  logic [AW-1:0] fnb  [0:2], ffb [0:2];   // near / far row bases of the line
  logic [1:0]    ninfl [0:2];          // column sums issued but not yet in the FIFO
  logic          rd_v  [0:2], rd_far [0:2];
  logic [1:0]    rd_lane [0:2];
  logic [7:0]    ntmp  [0:2];          // near sample waiting for its far sample
  logic [9:0]    fq    [0:2][0:2];     // FIFO of column sums
  logic [1:0]    fcnt  [0:2];
  logic          primed [0:2];         // horizontally filtered component: window loaded with cs[0]
  logic          push [0:2], pop [0:2], issue [0:2];

  logic          fetch_go [0:2];
  logic [14:0]   cw_last [0:2];        // last column of component c in this line
  integer c, k;
  always_comb begin
    for (c = 0; c < 3; c = c + 1) begin
      cw_last[c] = uh[c] ? cwl_m1 : wm1[14:0];
      // room: FIFO entries + column sums on their way < 3
      fetch_go[c] = (state == R_PRIME || state == R_PIX) && (c < nproc) && !fdone[c] &&
                    (fph[c] || ({1'b0, fcnt[c]} + {1'b0, ninfl[c]} < 3'd3));
    end
  end
  logic [31:0] fjw [0:2];
  always_comb for (c = 0; c < 3; c = c + 1) begin
    fjw[c] = {19'd0, fj[c][14:2]};                                  // word of column fj
    raddr[c*AW +: AW] = (fph[c] ? ffb[c] : fnb[c]) + fjw[c][AW-1:0];
  end

  // ---------------------------------------------------------------- pixel stage (P)
  logic [9:0]    csl [0:2], csc [0:2], csr [0:2];   // column-sum window
  logic          need [0:2];           // component pops a column sum for this pixel
  logic          shift [0:2];          // horizontal filter: slide the window
  logic          p_ok;                 // every needed FIFO has an entry
  logic          p_go;
  logic          p_last;
  // V / O stages
  logic          v_valid, v_conv, v_sof, v_eol, v_x0;
  logic          p_valid, p_x0, p_vline, p_sof, p_eol;
  logic [15:0]   p_x, p_y;
  logic [15:0]   v_x, v_y;
  logic [7:0]    v_a, v_b, v_c;
  logic          o_take, v_free, p_free;
  assign o_take = v_valid & (~px_valid | px_ready);
  assign v_free = ~v_valid | o_take;
  assign p_free = ~p_valid | v_free;

  always_comb begin
    p_ok = 1'b1;
    for (c = 0; c < 3; c = c + 1) begin
      if (hf[c]) begin
        shift[c] = (x != 16'd0) & ~x[0];                        // even pixel: next pair
        need[c]  = (x == 16'd0) | (shift[c] & ({1'b0, x[15:1]} + 16'd1 <= {1'b0, cwl_m1}));
      end else begin
        shift[c] = 1'b0;
        need[c]  = uh[c] ? ~x[0] : 1'b1;
      end
      if (c >= nproc) need[c] = 1'b0;
      if (need[c] && fcnt[c] == 2'd0) p_ok = 1'b0;
    end
  end
  assign p_go   = (state == R_PIX) && p_ok && p_free;
  assign p_last = (x == wm1);

  // filter output of component k for the pixel in stage V (window as updated by stage P)
  function automatic logic [7:0] upval(input logic [9:0] cc, input logic [9:0] nn, input logic [3:0] bias);
    logic [11:0] t;
    t = {1'b0, cc, 1'b0} + {2'b00, cc} + {2'b00, nn} + {8'd0, bias};
    upval = t[11:4];
  endfunction
  logic [7:0] val [0:2];
  logic [9:0] nbv;
  logic [3:0] bias;
  always_comb begin
    for (k = 0; k < 3; k = k + 1) begin
      nbv = hf[k] ? (p_x0 ? csl[k] : csr[k]) : csc[k];
      if (hf[k]) bias = vf[k] ? (p_x0 ? 4'd8 : 4'd7) : (p_x0 ? 4'd4 : 4'd8);   // h2v2 / h2v1 (p_x0: even pixel)
      else       bias = vf[k] ? (p_vline ? 4'd8 : 4'd4) : 4'd0;             // h1v2 / none
      val[k] = upval(csc[k], nbv, bias);
    end
  end

  logic [7:0] cv_r, cv_g, cv_b;
  jpeg_ycc2rgb #(.CC_TURBO(CC_TURBO)) u_cc (.y(v_a), .cb(v_b), .cr(v_c), .r(cv_r), .g(cv_g), .b(cv_b));

  assign idle = (state == R_IDLE) & ~p_valid & ~v_valid & ~px_valid;

  logic [3*AW-1:0] pbase_r;
  // next line: near row of component c advances after lower rows of vertical pairs
  logic [AW-1:0] far_n [0:2];
  logic          lnext_odd;
  always_comb begin
    for (c = 0; c < 3; c = c + 1) begin
      if (defer_r)             far_n[c] = gA(pbase_r, c);                       // row 0 of the next MCU row
      else if (!l[0]) begin                                                    // upper row: row above
        if (l[3:1] != 3'd0)    far_n[c] = nrow[c] - gA(pw, c);
        else if (first_r)      far_n[c] = nrow[c];                             // top edge
        else                   far_n[c] = lbr[c];                              // previous MCU row
      end else begin                                                           // lower row: row below
        if (lastrow_r && (l[3:1] >= lastcr)) far_n[c] = nrow[c];               // bottom edge
        else                   far_n[c] = nrow[c] + gA(pw, c);
      end
    end
  end

  logic [1:0] lane_c [0:2];
  logic [7:0] smp    [0:2];
  logic [31:0] rword [0:2];     // this component's 32-bit word (constant base: portable to Yosys)
  logic [9:0] cs_in  [0:2];
  logic prime_pop [0:2];
  logic prime_ok;
  always_comb begin
    prime_ok = 1'b1;
    for (c = 0; c < 3; c = c + 1) begin
      rword[c] = rdata[c*32 +: 32];
      case (rd_lane[c])
        2'd0:    smp[c] = rword[c][7:0];
        2'd1:    smp[c] = rword[c][15:8];
        2'd2:    smp[c] = rword[c][23:16];
        default: smp[c] = rword[c][31:24];
      endcase
      cs_in[c] = rd_far[c] ? ({ntmp[c], 1'b0} + {2'b00, ntmp[c]} + {2'b00, smp[c]}) : {smp[c], 2'b00};
      push[c]  = rd_v[c] && (!vf[c] || rd_far[c]);
      issue[c] = fetch_go[c] && !fph[c];                         // first read of a column goes out
      // (the window may only change once the previous line's last pixel has left stage P)
      prime_pop[c] = (state == R_PRIME) && !p_valid && (c < nproc) && hf[c] && !primed[c] && (fcnt[c] != 2'd0);
      pop[c]   = (p_go && need[c]) || prime_pop[c];
      if ((c < nproc) && hf[c] && !primed[c] && !prime_pop[c]) prime_ok = 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    done <= 1'b0;
    if (rst) begin
      state <= R_IDLE; defer_r <= 1'b0; first_r <= 1'b0; lastrow_r <= 1'b0; lines_left <= '0; l <= '0;
      x <= '0; y <= '0; wm1 <= '0; vline <= 1'b0; lastcr <= '0; cwl_m1 <= '0; pbase_r <= '0;
      p_valid <= 1'b0; p_x0 <= 1'b0; p_vline <= 1'b0; p_sof <= 1'b0; p_eol <= 1'b0; p_x <= '0; p_y <= '0;
      v_valid <= 1'b0; v_conv <= 1'b0; v_sof <= 1'b0; v_eol <= 1'b0; v_x0 <= 1'b0; v_x <= '0; v_y <= '0;
      v_a <= '0; v_b <= '0; v_c <= '0;
      px_valid <= 1'b0; px_x <= '0; px_y <= '0; px_c0 <= '0; px_c1 <= '0; px_c2 <= '0; px_sof <= 1'b0; px_eol <= 1'b0;
      for (c = 0; c < 3; c = c + 1) begin
        nrow[c] <= '0; lbr[c] <= '0; fj[c] <= '0; fdone[c] <= 1'b1; fph[c] <= 1'b0; fnb[c] <= '0; ffb[c] <= '0;
        ninfl[c] <= '0; rd_v[c] <= 1'b0; rd_far[c] <= 1'b0; rd_lane[c] <= '0; ntmp[c] <= '0; fcnt[c] <= '0;
        primed[c] <= 1'b0;
        csl[c] <= '0; csc[c] <= '0; csr[c] <= '0;
        for (k = 0; k < 3; k = k + 1) fq[c][k] <= '0;
      end
    end else begin
      // ---- O stage
      if (px_valid & px_ready) px_valid <= 1'b0;
      if (o_take) begin
        px_valid <= 1'b1; px_x <= v_x; px_y <= v_y; px_sof <= v_sof; px_eol <= v_eol;
        px_c0 <= (RGB_OUT && v_conv) ? cv_r : v_a;
        px_c1 <= (RGB_OUT && v_conv) ? cv_g : v_b;
        px_c2 <= (RGB_OUT && v_conv) ? cv_b : v_c;
        v_valid <= 1'b0;
      end
      // ---- V stage: filter outputs from the windows as stage P left them
      if (p_valid && v_free) begin
        v_valid <= 1'b1; v_x <= p_x; v_y <= p_y; v_sof <= p_sof; v_eol <= p_eol;
        v_a <= val[0];
        if (gray || fmt == FMT_Y || nproc == 2'd1) begin
          v_b <= (RGB_OUT && gray && fmt == FMT_RGB) ? val[0] : 8'd128;
          v_c <= (RGB_OUT && gray && fmt == FMT_RGB) ? val[0] : 8'd128;
          v_conv <= 1'b0;
        end else begin
          v_b <= val[1]; v_c <= val[2];
          v_conv <= RGB_OUT && (fmt == FMT_RGB);
        end
        p_valid <= 1'b0;
      end

      // ---- fetchers: RAM data of last cycle's read -> column sum -> FIFO
      for (c = 0; c < 3; c = c + 1) begin
        rd_v[c] <= 1'b0;
        if (rd_v[c]) begin
          if (vf[c] && !rd_far[c]) ntmp[c] <= smp[c];                  // near half of a filtered column
        end
      end
      for (c = 0; c < 3; c = c + 1) begin
        if (fetch_go[c]) begin
          rd_v[c] <= 1'b1; rd_far[c] <= fph[c]; rd_lane[c] <= fj[c][1:0];
          if (vf[c] && !fph[c]) fph[c] <= 1'b1;                        // far sample next
          else begin
            fph[c] <= 1'b0;
            if (fj[c] == cw_last[c]) fdone[c] <= 1'b1; else fj[c] <= fj[c] + 15'd1;
          end
        end
      end

      // ---- FIFO bookkeeping (push from the fetcher, pop by stage P / window priming)
      for (c = 0; c < 3; c = c + 1) begin
        if (issue[c] && !push[c])      ninfl[c] <= ninfl[c] + 2'd1;   // column sums on their way
        else if (push[c] && !issue[c]) ninfl[c] <= ninfl[c] - 2'd1;
        if (pop[c]) begin
          fq[c][0] <= fq[c][1]; fq[c][1] <= fq[c][2];
          if (push[c]) fq[c][fcnt[c] - 2'd1] <= cs_in[c];
        end else if (push[c]) fq[c][fcnt[c]] <= cs_in[c];
        fcnt[c] <= fcnt[c] + {1'b0, push[c]} - {1'b0, pop[c]};
      end

      case (state)
        R_IDLE: if (start) begin
          defer_r   <= (mode == CMD_DEFER);
          first_r   <= first_row;
          lastrow_r <= lastrow;
          lastcr    <= (img_h[3:0] - 4'd1) >> 1;
          lines_left <= (mode == CMD_DEFER) ? 5'd1 : nlines;
          l <= '0; y <= y0; wm1 <= img_w - 16'd1;
          cwl_m1 <= img_w[15:1] + {14'd0, img_w[0]} - 15'd1;          // ceil(W/2) - 1
          pbase_r <= pbase;
          for (c = 0; c < 3; c = c + 1) begin
            nrow[c] <= (mode == CMD_DEFER) ? gA(lbase, c) : gA(pbase, c);
            lbr[c]  <= gA(lbase, c);
          end
          state <= R_LINE;
        end
        // ---- line setup: row bases, fetchers restart at column 0
        R_LINE: begin
          vline <= defer_r ? 1'b1 : l[0];
          x <= '0;
          for (c = 0; c < 3; c = c + 1) begin
            fnb[c] <= nrow[c]; ffb[c] <= far_n[c];
            fj[c] <= '0; fph[c] <= 1'b0; fdone[c] <= 1'b0; primed[c] <= 1'b0;
          end
          state <= R_PRIME;
        end
        // ---- horizontally filtered components: csl = csc = cs[0] before pixel 0
        R_PRIME: begin
          for (c = 0; c < 3; c = c + 1)
            if (prime_pop[c]) begin csl[c] <= fq[c][0]; csc[c] <= fq[c][0]; primed[c] <= 1'b1; end
          if (prime_ok) state <= R_PIX;
        end
        // ---- one pixel per clock
        R_PIX: if (p_go) begin
          for (c = 0; c < 3; c = c + 1) begin
            if (hf[c]) begin
              if (x == 16'd0) csr[c] <= fq[c][0];
              else if (shift[c]) begin
                csl[c] <= csc[c]; csc[c] <= csr[c];
                if (need[c]) csr[c] <= fq[c][0];                       // (else: right edge, keep)
              end
            end else if (need[c]) csc[c] <= fq[c][0];
          end
          p_valid <= 1'b1; p_x <= x; p_y <= y; p_x0 <= ~x[0]; p_vline <= vline;
          p_sof <= (x == 16'd0) && (y == 16'd0); p_eol <= p_last;
          if (p_last) begin
            for (c = 0; c < 3; c = c + 1)
              if (!uv[c] || l[0] || defer_r) nrow[c] <= nrow[c] + gA(pw, c);
            if (lines_left == 5'd1) begin done <= 1'b1; state <= R_IDLE; end
            else begin
              lines_left <= lines_left - 5'd1; l <= l + 4'd1; y <= y + 16'd1;
              state <= R_LINE;
            end
          end else x <= x + 16'd1;
        end
        default: state <= R_IDLE;
      endcase
    end
  end
endmodule
