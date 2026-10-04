// jpeg_dec_wide.sv - wide core of jpeg_decoder (FAST = 2): four pixels per clock, MCU order.
//
//   bytes -> jpeg_parser (+ Huffman lookahead tables) -> jpeg_bitwin -> jpeg_huffdec
//         -> 4 coefficient slots -> jpeg_idct_wide (8 clocks per block) -> one sample RAM per
//            component (64-bit words: 8 samples), NBUF = 3 MCU buffers -> jpeg_mcuout_wide
//            (4 pixels per clock)
//
// The input side (parser, block sequencing, restarts, errors, frame completion) is that of
// jpeg_dec_fast in MCU order; the output side holds three MCUs, so the IDCT can fill two while
// the third is emitted, and emits four pixels per beat (px_n of them valid).  The faster entropy
// decoder and IDCT of the wide design (WIDE_STATUS.md) replace jpeg_huffdec / jpeg_idct_fast here
// step by step.  Pixels, errors and handshakes are identical to the other cores.
module jpeg_dec_wide #(
  parameter bit CC_TURBO       = 1'b0,
  parameter bit RGB_OUT        = 1'b1,
  parameter bit CHECKS         = 1'b1
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        in_valid,
  input  logic [7:0]  in_data,
  input  logic        in_last,
  output logic        in_ready,
  input  logic [1:0]  out_fmt,
  output logic        px_valid,
  input  logic        px_ready,
  output logic [15:0] px_x,
  output logic [15:0] px_y,
  output logic [2:0]  px_n,
  output logic [31:0] px_c0,
  output logic [31:0] px_c1,
  output logic [31:0] px_c2,
  output logic        px_sof,
  output logic        px_eol,
  output logic [15:0] img_w,
  output logic [15:0] img_h,
  output logic        frame_start,
  output logic        frame_done,
  output logic [12:0] err
);
  import jpeg_pkg::*;

  localparam int SAW = 7;                    // sample-RAM word address: {MCU buffer (0..2), word (0..31)}
  // block descriptor: {last block of MCU, block row, scan component, word offset}
  localparam int D_COMP = SAW, D_VV = SAW + 2, D_LAST = SAW + 3;
  localparam int DW     = SAW + 4;

  // ---------------------------------------------------------------- parser + tables
  logic        p_in_valid, p_in_ready, p_idle, p_soi;
  logic        dqt_we, hc_we, hv_we, lut_we;
  logic [7:0]  dqt_waddr, dqt_wdata, hv_wdata;
  logic [5:0]  hc_waddr;
  logic [24:0] hc_wdata;
  logic [8:0]  hv_waddr;
  logic [9:0]  lut_waddr;
  logic [11:0] lut_wdata;
  logic [1:0]  nf, ns;
  logic [11:0] comp_h, comp_v;
  logic [7:0]  comp_tq, scan_ci;
  logic [3:0]  scan_td, scan_ta;
  logic [15:0] ri;
  logic        scan_start, eoi;
  logic        tok_valid, tok_ready;
  logic [8:0]  tok_data;
  logic [12:0] err_set;
  logic        decoding;
  logic        skip_img, eoi_seen;   // unusable image: consume its scans until its EOI

  assign p_in_valid = in_valid & ~(decoding & p_idle);
  assign in_ready   = p_in_ready & ~(decoding & p_idle);

  jpeg_parser #(.LUT_EN(1'b1), .CHECKS(CHECKS)) u_parser (
    .clk(clk), .rst(rst),
    .in_valid(p_in_valid), .in_data(in_data), .in_last(in_last), .in_ready(p_in_ready), .idle(p_idle),
    .dqt_we(dqt_we), .dqt_waddr(dqt_waddr), .dqt_wdata(dqt_wdata),
    .hc_we(hc_we), .hc_waddr(hc_waddr), .hc_wdata(hc_wdata),
    .hv_we(hv_we), .hv_waddr(hv_waddr), .hv_wdata(hv_wdata),
    .lut_we(lut_we), .lut_waddr(lut_waddr), .lut_wdata(lut_wdata),
    .img_w(img_w), .img_h(img_h), .nf(nf), .comp_h(comp_h), .comp_v(comp_v), .comp_tq(comp_tq),
    .ns(ns), .scan_ci(scan_ci), .scan_td(scan_td), .scan_ta(scan_ta), .ri(ri), .scan_start(scan_start),
    .tok_valid(tok_valid), .tok_data(tok_data), .tok_ready(tok_ready),
    .eoi(eoi), .soi(p_soi), .err_set(err_set));

  logic [7:0]  dqt_raddr, dqt_rdata, hv_rdata;
  logic [5:0]  hc_raddr;
  logic [24:0] hc_rdata;
  logic [8:0]  hv_raddr;
  logic [9:0]  lut_raddr;
  logic [11:0] lut_rdata;
  // (all table RAMs are read through the block RAMs' output registers: 2 clocks)
  jpeg_sdp_ram #(.WIDTH(8),  .DEPTH_LOG2(8), .OUT_REG(1'b1)) u_dqt (.clk(clk), .we(dqt_we), .waddr(dqt_waddr), .wdata(dqt_wdata), .raddr(dqt_raddr), .rdata(dqt_rdata));
  jpeg_sdp_ram #(.WIDTH(25), .DEPTH_LOG2(6), .OUT_REG(1'b1))  u_hc  (.clk(clk), .we(hc_we),  .waddr(hc_waddr),  .wdata(hc_wdata),  .raddr(hc_raddr),  .rdata(hc_rdata));
  jpeg_sdp_ram #(.WIDTH(8),  .DEPTH_LOG2(9), .OUT_REG(1'b1))  u_hv  (.clk(clk), .we(hv_we),  .waddr(hv_waddr),  .wdata(hv_wdata),  .raddr(hv_raddr),  .rdata(hv_rdata));
  jpeg_sdp_ram #(.WIDTH(12), .DEPTH_LOG2(10), .OUT_REG(1'b1)) u_lut (.clk(clk), .we(lut_we), .waddr(lut_waddr), .wdata(lut_wdata), .raddr(lut_raddr), .rdata(lut_rdata));

  // ---------------------------------------------------------------- bit window + block decoder
  logic [47:0] acc;
  logic [5:0]  wcnt;
  logic        eod, w_consume, restart_req, restart_done, err_pad, br_clear, br_at_end;
  logic [4:0]  w_n;
  jpeg_bitwin u_win (
    .clk(clk), .rst(rst), .clear(br_clear),
    .tok_valid(tok_valid), .tok_data(tok_data), .tok_ready(tok_ready),
    .acc(acc), .wcnt(wcnt), .eod(eod), .consume(w_consume), .n(w_n),
    .restart_req(restart_req), .restart_done(restart_done), .err_pad(err_pad), .at_end(br_at_end));

  logic        hd_start, hd_idle, hd_done, hd_err, pred_clear, hd_wr;
  logic        cw_we;
  logic [5:0]  cw_addr;
  logic signed [15:0] cw_data;
  logic [1:0]  cur_ci, cd_tq;
  logic        cd_dc, cd_ac;
  jpeg_huffdec u_hd (
    .clk(clk), .rst(rst),
    .start(hd_start), .comp(cur_ci), .dc_tbl(cd_dc), .ac_tbl(cd_ac), .tq(cd_tq), .wr_en(hd_wr), .pred_clear(pred_clear),
    .idle(hd_idle), .done(hd_done), .err_huff(hd_err),
    .acc(acc), .wcnt(wcnt), .consume(w_consume), .n(w_n),
    .lut_raddr(lut_raddr), .lut_rdata(lut_rdata), .hc_raddr(hc_raddr), .hc_rdata(hc_rdata),
    .hv_raddr(hv_raddr), .hv_rdata(hv_rdata), .dqt_raddr(dqt_raddr), .dqt_rdata(dqt_rdata),
    .cw_we(cw_we), .cw_addr(cw_addr), .cw_data(cw_data));

  // ---------------------------------------------------------------- IDCT
  // tag carried through pass 2: {MCU buffer, last block of MCU, component}
  logic           cw_ready, cw_commit, p2_pending, p2_ok, smp_we, blk_done, id_busy;
  logic [3:0]     clean;
  logic [1:0]     wp;                        // slot the entropy decoder fills (slots in order)
  logic [DW-1:0]  cw_desc, p2_desc;
  logic [4:0]     p2_tag, smp_tag, blk_tag;
  logic [SAW-1:0] p2_base, p2_pitch, smp_addr;
  logic [63:0]    smp_data;
  assign p2_tag   = {p2_desc[6:5], p2_desc[D_LAST], p2_desc[D_COMP +: 2]};
  assign cw_ready = clean[wp];
  jpeg_idct_wide #(.DW(DW), .TW(5), .SAW(SAW)) u_idct (
    .clk(clk), .rst(rst),
    .clean(clean), .cw_we(cw_we), .cw_slot(wp), .cw_addr(cw_addr), .cw_data(cw_data),
    .cw_commit(cw_commit), .cw_cslot(wp), .cw_desc(cw_desc),
    .p2_pending(p2_pending), .p2_desc(p2_desc), .p2_ok(p2_ok), .p2_base(p2_base), .p2_pitch(p2_pitch),
    .p2_tag(p2_tag), .smp_we(smp_we), .smp_addr(smp_addr), .smp_data(smp_data), .smp_tag(smp_tag),
    .blk_done(blk_done), .blk_tag(blk_tag), .busy(id_busy));
  always_ff @(posedge clk) begin
    if (rst) wp <= '0;
    else if (cw_commit) wp <= wp + 2'd1;
  end

  // ---------------------------------------------------------------- frame state
  logic        gray, hmax2, vmax2;
  logic [2:0]  h2, v2, uh_r, uv_r;
  logic [1:0]  fmt_r, nstore;
  logic        out_fin;                      // output side finished with the frame
  logic        out_idle;                     // output pipeline empty

  // ---------------------------------------------------------------- input side: block sequencing
  typedef enum logic [3:0] { S_IDLE, S_SETUP, S_GEO1, S_BLK, S_BLK_WAIT, S_RESTART, S_DRAIN, S_SKIP, S_DONE } state_t;
  state_t state;

  logic [1:0]  j;
  logic        vv, hh;
  logic [15:0] mcu_w, mcu_h;
  logic [15:0] rst_cnt;
  logic [12:0] mx, my, mcux_m1, mcuy_m1;
  logic [13:0] mcux;
  logic [1:0]  in_buf;                       // MCU buffer of the MCU being decoded (0..2)
  logic        cur_skip;
  logic [DW-1:0] cur_desc;
  integer      gi;

  function automatic logic is2(input logic [11:0] hv, input logic [1:0] c);
    is2 = (hv[3*c +: 3] == 3'd2);
  endfunction
  function automatic logic [1:0] ci_of(input logic [7:0] sc, input logic [1:0] jj);
    ci_of = sc[2*jj +: 2];
  endfunction
  logic hmax2_c, vmax2_c;
  assign hmax2_c = (nf == 2'd1) ? 1'b0 : (is2(comp_h, ci_of(scan_ci, 2'd0)) | is2(comp_h, ci_of(scan_ci, 2'd1)) | is2(comp_h, ci_of(scan_ci, 2'd2)));
  assign vmax2_c = (nf == 2'd1) ? 1'b0 : (is2(comp_v, ci_of(scan_ci, 2'd0)) | is2(comp_v, ci_of(scan_ci, 2'd1)) | is2(comp_v, ci_of(scan_ci, 2'd2)));

  logic cur_h2, cur_v2, last_blk_of_comp, last_comp, skip_idct, more_x, more_y, last_nonskip;
  logic [15:0] wm1_c, hm1_c;
  localparam logic [12:0] hdr_err_mask = (13'd1 << ERR_SOF_TYPE) | (13'd1 << ERR_PRECISION) | (13'd1 << ERR_DQT)
                                       | (13'd1 << ERR_DHT) | (13'd1 << ERR_NCOMP) | (13'd1 << ERR_SAMPLING)
                                       | (13'd1 << ERR_SCAN) | (13'd1 << ERR_FRAME) | (13'd1 << ERR_TRUNC);
  assign cur_ci   = ci_of(scan_ci, j);
  assign cur_h2   = h2[j];
  assign cur_v2   = v2[j];
  assign cd_dc    = scan_td[j];
  assign cd_ac    = scan_ta[j];
  assign cd_tq    = comp_tq[2*cur_ci +: 2];
  assign wm1_c    = img_w - 16'd1;
  assign hm1_c    = img_h - 16'd1;
  assign last_blk_of_comp = (hh == cur_h2) && (vv == cur_v2);
  assign last_comp        = (j == ns - 2'd1);
  assign skip_idct        = (fmt_r == FMT_Y) && (j != 2'd0);
  assign last_nonskip     = last_blk_of_comp && ((fmt_r == FMT_Y) ? (j == 2'd0) : last_comp);
  assign more_x           = (mx != mcux_m1);
  assign more_y           = (my != mcuy_m1);
  assign hd_wr            = ~skip_idct;

  // ---- descriptor of the current block
  logic [4:0]     blk_off;                   // word offset in the component's plane (8 samples per word)
  assign blk_off = (vv ? (cur_h2 ? 5'd16 : 5'd8) : 5'd0) + (hh ? 5'd1 : 5'd0);

  // commit a decoded block to the IDCT in the cycle its decoder finishes (wp advances at once)
  assign cw_commit = (state == S_BLK_WAIT) && hd_done && !cur_skip;
  assign cw_desc   = cur_desc;

  always_ff @(posedge clk) begin
    hd_start <= 1'b0; pred_clear <= 1'b0; frame_start <= 1'b0; frame_done <= 1'b0; br_clear <= 1'b0;
    if (rst) begin
      state <= S_IDLE; decoding <= 1'b0; restart_req <= 1'b0; err <= '0; skip_img <= 1'b0; eoi_seen <= 1'b0;
      j <= '0; vv <= 1'b0; hh <= 1'b0; mcu_w <= '0; mcu_h <= '0; rst_cnt <= '0;
      gray <= 1'b0; hmax2 <= 1'b0; vmax2 <= 1'b0; h2 <= '0; v2 <= '0; fmt_r <= FMT_RGB; nstore <= 2'd3;
      mx <= '0; my <= '0; mcux <= '0; mcux_m1 <= '0; mcuy_m1 <= '0; in_buf <= '0;
      cur_skip <= 1'b0; cur_desc <= '0;
      uh_r <= '0; uv_r <= '0;
    end else begin
      // errors of the current image: cleared when the next image's SOI is accepted (the parser
      // is held at that SOI until frame_done, so err describes the last frame until then)
      err <= (p_soi ? 13'd0 : err) | err_set | ({12'd0, hd_err} << ERR_HUFF) | ({12'd0, err_pad & (state != S_DRAIN) & (state != S_SKIP)} << ERR_MARKER);

      if (eoi) eoi_seen <= 1'b1;
      case (state)
        S_IDLE: if (scan_start) begin
          decoding <= 1'b1; frame_start <= 1'b1; eoi_seen <= 1'b0;
          if (img_w == 16'd0 || img_h == 16'd0) err[ERR_FRAME] <= 1'b1;   // X or Y = 0 (DNL), or no SOF
          if (img_w == 16'd0 || img_h == 16'd0 || (hdr_err_mask & (err_set | err)) != 13'd0) begin
            skip_img <= 1'b1; state <= S_DRAIN;               // no pixels: consume the image's scans
          end else state <= S_SETUP;
        end
        S_SETUP: begin
          gray   <= (nf == 2'd1);
          fmt_r  <= out_fmt;
          nstore <= ((nf == 2'd1) || (out_fmt == FMT_Y)) ? 2'd1 : 2'd3;
          hmax2  <= hmax2_c; vmax2 <= vmax2_c;
          mcu_w  <= hmax2_c ? 16'd16 : 16'd8;
          mcu_h  <= vmax2_c ? 16'd16 : 16'd8;
          mcux   <= hmax2_c ? ({2'b00, img_w[15:4]} + {13'd0, |img_w[3:0]}) : ({1'b0, img_w[15:3]} + {13'd0, |img_w[2:0]});
          mcux_m1 <= hmax2_c ? {1'b0, wm1_c[15:4]} : wm1_c[15:3];
          mcuy_m1 <= vmax2_c ? {1'b0, hm1_c[15:4]} : hm1_c[15:3];
          if (nf == 2'd1) begin h2 <= 3'b000; v2 <= 3'b000; end
          else begin
            h2 <= {is2(comp_h, ci_of(scan_ci, 2'd2)), is2(comp_h, ci_of(scan_ci, 2'd1)), is2(comp_h, ci_of(scan_ci, 2'd0))};
            v2 <= {is2(comp_v, ci_of(scan_ci, 2'd2)), is2(comp_v, ci_of(scan_ci, 2'd1)), is2(comp_v, ci_of(scan_ci, 2'd0))};
          end
          mx <= '0; my <= '0; j <= '0; vv <= 1'b0; hh <= 1'b0; in_buf <= '0;
          rst_cnt <= ri; pred_clear <= 1'b1;
          state <= S_GEO1;
        end
        S_GEO1: begin
          for (gi = 0; gi < 3; gi = gi + 1) begin
            uh_r[gi] <= hmax2 & ~h2[gi];
            uv_r[gi] <= vmax2 & ~v2[gi];
          end
          state <= S_BLK;
        end
        S_BLK: if (hd_idle && (skip_idct || cw_ready)) begin
          hd_start <= 1'b1; cur_skip <= skip_idct;
          cur_desc <= {last_nonskip, vv, j, in_buf, blk_off};
          state <= S_BLK_WAIT;
        end
        S_BLK_WAIT: if (hd_done) begin
          if (!last_blk_of_comp) begin
            if (hh == cur_h2) begin hh <= 1'b0; vv <= 1'b1; end
            else hh <= 1'b1;
            state <= S_BLK;
          end else if (!last_comp) begin
            hh <= 1'b0; vv <= 1'b0; j <= j + 2'd1; state <= S_BLK;
          end else begin                                       // MCU complete
            hh <= 1'b0; vv <= 1'b0; j <= '0; in_buf <= (in_buf == 2'd2) ? 2'd0 : in_buf + 2'd1;
            rst_cnt <= rst_cnt - 16'd1;
            if (more_x || more_y) begin
              if (more_x) mx <= mx + 13'd1;
              else begin mx <= '0; my <= my + 13'd1; end
              state <= (ri != 16'd0 && rst_cnt == 16'd1) ? S_RESTART : S_BLK;
            end else state <= S_DRAIN;
          end
        end
        S_RESTART: begin                                        // T.81 F.2.2.5 / B.2.4.4
          restart_req <= 1'b1;
          if (restart_done) begin
            restart_req <= 1'b0; pred_clear <= 1'b1; rst_cnt <= ri; state <= S_BLK;
          end
        end
        S_DRAIN: begin                                          // skip to the marker ending the scan
          restart_req <= 1'b1;
          if (restart_done) begin
            restart_req <= 1'b0;
            if (br_at_end) begin
              if (skip_img) begin br_clear <= 1'b1; state <= S_SKIP; end
              else state <= S_DONE;
            end
          end
        end
        // an unusable image (e.g. progressive) may have more scans: consume them all, and end the
        // frame once, at the image's EOI
        S_SKIP: if (eoi_seen || eoi) begin skip_img <= 1'b0; state <= S_DONE; end
                else if (scan_start) state <= S_DRAIN;
        S_DONE: if (out_fin && !id_busy && out_idle) begin      // wait for the last pixel
          frame_done <= 1'b1; decoding <= 1'b0; br_clear <= 1'b1; state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  // ================================================================ output side
  // ---- MCU buffer: one RAM per component, three MCUs of 32 words of 8 samples
  function automatic logic [1:0] nxt3(input logic [1:0] b);
    nxt3 = (b == 2'd2) ? 2'd0 : b + 2'd1;
  endfunction
  logic [2:0]  mcu_full, mcu_started;        // per buffer: complete / being emitted
  logic [6:0]  mo_raddr [0:2];
  logic [63:0] mo_rdata [0:2];
  genvar gc;
  generate
    for (gc = 0; gc < 3; gc = gc + 1) begin : g_mbuf
      jpeg_sdp_ram #(.WIDTH(64), .DEPTH_LOG2(7), .DEPTH(96)) u_mb (
        .clk(clk), .we(smp_we && smp_tag[1:0] == gc), .waddr(smp_addr), .wdata(smp_data),
        .raddr(mo_raddr[gc]), .rdata(mo_rdata[gc]));
    end
  endgenerate
  assign p2_base  = p2_desc[SAW-1:0];
  assign p2_pitch = h2[p2_desc[D_COMP +: 2]] ? 7'd2 : 7'd1;
  assign p2_ok    = ~mcu_full[p2_desc[6:5]];

  logic        mo_start, mo_done, mo_idle, mo_ready;
  logic [1:0]  os_buf, od_buf;               // buffer of the next MCU to start / to finish
  logic [12:0] omx, omy;
  logic [15:0] ox0, oy0, ow, ol;
  logic        out_expect, all_started;
  logic [4:0]  mo_width, mo_lines;
  assign ow       = img_w - ox0;
  assign ol       = img_h - oy0;
  assign mo_width = (ow > mcu_w) ? mcu_w[4:0] : ow[4:0];
  assign mo_lines = (ol > mcu_h) ? mcu_h[4:0] : ol[4:0];
  assign mo_start = out_expect && !all_started && mo_ready && mcu_full[os_buf] && !mcu_started[os_buf];
  assign out_fin  = all_started;
  assign out_idle = mo_idle;

  jpeg_mcuout_wide #(.CC_TURBO(CC_TURBO), .RGB_OUT(RGB_OUT)) u_mo (
    .clk(clk), .rst(rst), .start(mo_start), .buf_i(os_buf), .x0(ox0), .y0(oy0), .width(mo_width), .nlines(mo_lines),
    .done(mo_done), .idle(mo_idle), .ready(mo_ready),
    .img_w(img_w), .gray(gray), .fmt(fmt_r), .uh(uh_r), .uv(uv_r), .h2(h2),
    .raddr0(mo_raddr[0]), .raddr1(mo_raddr[1]), .raddr2(mo_raddr[2]),
    .rdata0(mo_rdata[0]), .rdata1(mo_rdata[1]), .rdata2(mo_rdata[2]),
    .px_valid(px_valid), .px_ready(px_ready), .px_x(px_x), .px_y(px_y), .px_n(px_n),
    .px_c0(px_c0), .px_c1(px_c1), .px_c2(px_c2), .px_sof(px_sof), .px_eol(px_eol));

  always_ff @(posedge clk) begin
    if (rst) begin
      mcu_full <= '0; mcu_started <= '0; os_buf <= '0; od_buf <= '0;
      omx <= '0; omy <= '0; ox0 <= '0; oy0 <= '0; all_started <= 1'b1; out_expect <= 1'b0;
    end else if (state == S_IDLE && scan_start) begin
      out_expect <= 1'b0; all_started <= 1'b1;             // until S_SETUP: nothing to emit
    end else if (state == S_SETUP) begin
      mcu_full <= '0; mcu_started <= '0; os_buf <= '0; od_buf <= '0;
      omx <= '0; omy <= '0; ox0 <= '0; oy0 <= '0; all_started <= 1'b0; out_expect <= 1'b1;
    end else begin
      if (blk_done && blk_tag[2]) mcu_full[blk_tag[4:3]] <= 1'b1;
      if (mo_start) begin
        mcu_started[os_buf] <= 1'b1; os_buf <= nxt3(os_buf);
        if (omx != mcux_m1) begin omx <= omx + 13'd1; ox0 <= ox0 + mcu_w; end
        else begin
          omx <= '0; ox0 <= '0;
          if (omy != mcuy_m1) begin omy <= omy + 13'd1; oy0 <= oy0 + mcu_h; end
          else all_started <= 1'b1;                        // last MCU started
        end
      end
      if (mo_done) begin
        mcu_full[od_buf] <= 1'b0; mcu_started[od_buf] <= 1'b0; od_buf <= nxt3(od_buf);
      end
    end
  end
endmodule
