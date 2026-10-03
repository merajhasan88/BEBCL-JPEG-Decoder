// uart_bench_core.sv - feeds one JPEG decoder (the DUT) with a file received over a UART and
// measures the decoder's own clock count with an ideal input, for this library and for two other
// open-source FPGA JPEG decoders, so that all three are measured the same way on one board.
// Vendor-neutral; the board top supplies the clocks.
//
// Clocks:
//   clk   free-running core clock (UART, FIFO, control)
//   dclk  the DUT's clock: clk gated by run_en (a glitch-free clock buffer such as a Xilinx 7-series
//         BUFGCE, whose enable decides each rising edge).  run_en is high only while the DUT's next
//         input is waiting (or during reset, or after the last input byte until the frame is done),
//         so at every dclk edge the DUT sees its input available: `clocks` is the decode time with
//         an ideal input, independent of the serial speed.  (Same scheme as boards/ep2c5/rtl/jtag_stream_core.sv.)
//
// DUT 0: jpeg_decoder (this library: FAST=1, MCU order, RGB), byte input, in_last on the last byte
// DUT 1: ultraembedded core_jpeg (jpeg_core), 32-bit input words (first byte in bits 7:0)
// DUT 2: H. Ishihara's aq_djpeg (via ultraembedded legacy_jpeg_decoder), 32-bit input words
// The other decoders' sources are not part of this library (bench/others/fetch.sh fetches them).
//
// Protocol (8N1 at BAUD):
//   host -> FPGA: 0x55 0xAA 'J' 'P' len[31:0] (big-endian), then len bytes of the file
//   FPGA -> host, when the frame is done or the watchdog fires, 32 bytes (big-endian fields):
//     'R' 'E' 'S' DUT | flags | 0 0 0 | clocks[31:0] | checksum[31:0] | err[15:0] | width[15:0] |
//     height[15:0] | pixels[31:0] | bytes[31:0] | 0 0
//   flags: bit 0 FIFO overflow, bit 1 watchdog (no pixel for WATCHDOG decoder clocks: a decoder
//   that hangs still ends with a result), bit 2 done.  checksum = sum over pixels of {(x ^ y)[7:0], R, G, B} mod 2^32
//   (the EP2C5 boards' checksum), so it is independent of the pixel order.
module uart_bench_core #(
  parameter int DUT      = 0,
  parameter int CLK_HZ   = 100_000_000,
  parameter int BAUD     = 1_000_000,
  parameter int FIFO_AW  = 12,                 // 4 KB input FIFO
  parameter int WATCHDOG = 1 << 26
) (
  input  logic       clk,
  input  logic       rst,                      // clk domain, synchronous
  input  logic       dclk,                     // clk gated by run_en
  output logic       run_en,
  input  logic       uart_rx,
  output logic       uart_tx,
  output logic [3:0] led
);
  localparam int DIV = (CLK_HZ + BAUD / 2) / BAUD;   // clocks per bit
  localparam bit WORDS = (DUT != 0);

  // ================================================================ UART receiver
  logic [2:0]  rxs;
  logic        rxd, rbusy, rx_v;
  logic [15:0] rcnt;
  logic [3:0]  rbit;
  logic [7:0]  rsh, rx_b;
  always_ff @(posedge clk) rxs <= {rxs[1:0], uart_rx};
  assign rxd = rxs[2];
  always_ff @(posedge clk) begin
    rx_v <= 1'b0;
    if (rst) begin rbusy <= 1'b0; rcnt <= '0; rbit <= '0; end
    else if (!rbusy) begin
      if (!rxd) begin rbusy <= 1'b1; rcnt <= DIV[15:0] / 16'd2; rbit <= 4'd0; end
    end else if (rcnt != 16'd0) rcnt <= rcnt - 16'd1;
    else begin
      rcnt <= DIV[15:0] - 16'd1;
      if (rbit == 4'd0) begin if (rxd) rbusy <= 1'b0; else rbit <= 4'd1; end   // middle of the start bit
      else if (rbit <= 4'd8) begin rsh <= {rxd, rsh[7:1]}; rbit <= rbit + 4'd1; end
      else begin rbusy <= 1'b0; if (rxd) begin rx_v <= 1'b1; rx_b <= rsh; end end   // stop bit
    end
  end

  // ================================================================ protocol
  typedef enum logic [2:0] { H0, H1, H2, H3, LEN, DATA, WAIT } pstate_t;
  pstate_t     ps;
  logic [31:0] len, nrx;
  logic [1:0]  lk;
  logic        restart_req, push, eos;
  logic [7:0]  push_b;
  logic        done_seen, sent;
  always_ff @(posedge clk) begin
    restart_req <= 1'b0; push <= 1'b0;
    if (rst) begin ps <= H0; len <= '0; nrx <= '0; lk <= '0; eos <= 1'b0; end
    else begin
      if (rx_v) case (ps)
        H0:   ps <= (rx_b == 8'h55) ? H1 : H0;
        H1:   ps <= (rx_b == 8'hAA) ? H2 : (rx_b == 8'h55) ? H1 : H0;
        H2:   ps <= (rx_b == 8'h4A) ? H3 : H0;
        H3:   if (rx_b == 8'h50) begin ps <= LEN; lk <= '0; end else ps <= H0;
        LEN:  begin
          len <= {len[23:0], rx_b}; lk <= lk + 2'd1;
          if (lk == 2'd3) begin ps <= DATA; nrx <= '0; eos <= 1'b0; restart_req <= 1'b1; end
        end
        DATA: begin
          push <= 1'b1; push_b <= rx_b; nrx <= nrx + 32'd1;
          if (nrx + 32'd1 == len) begin eos <= 1'b1; ps <= WAIT; end
        end
        default: ;
      endcase
      if (ps == WAIT && sent) ps <= H0;          // result sent: ready for the next file
      if (ps == DATA && len == 32'd0) begin eos <= 1'b1; ps <= WAIT; end
    end
  end

  // ================================================================ input FIFO and the DUT's head
  logic [FIFO_AW:0] wp, rp;
  logic [7:0]       rdata, hd;
  logic             hd_v, rd_pend, ovf, in_rst, nb, fifo_empty, fifo_full;
  logic [3:0]       rst_cnt;
  assign fifo_empty = (wp == rp);
  assign fifo_full  = (wp[FIFO_AW] != rp[FIFO_AW]) && (wp[FIFO_AW-1:0] == rp[FIFO_AW-1:0]);
  jpeg_sdp_ram #(.WIDTH(8), .DEPTH_LOG2(FIFO_AW)) u_fifo (
    .clk(clk), .we(push && !fifo_full), .waddr(wp[FIFO_AW-1:0]), .wdata(push_b),
    .raddr(rp[FIFO_AW-1:0]), .rdata(rdata));

  // the head (byte for DUT 0, 32-bit word for the others); dv = offered to the DUT
  logic        dv, take, dut_ready, last_b, eos1, eos2;
  logic [31:0] wd;
  logic [2:0]  wn;                             // bytes in wd
  logic        done_d;                         // dclk domain: frame finished (or watchdog)
  logic        all_in;                         // every input byte handed to the DUT
  // eos rises with the last byte's push: eos2 is it two clocks later, when the FIFO has it
  always_ff @(posedge clk) begin eos1 <= eos && !restart_req; eos2 <= eos1 && eos && !restart_req; end
  assign take   = run_en && dv && dut_ready;   // the DUT takes its input at this (dclk = clk) edge
  assign all_in = eos2 && fifo_empty && !rd_pend && !hd_v && !dv && (wn == 3'd0);
  // the clock enable: reset, input waiting, or input finished and the frame still running.  A
  // 7-series BUFGCE passes a rising edge when its enable is high just before it (its latch is
  // transparent while the clock is low), so run_en may come from logic on registers.
  assign run_en = in_rst || dv || (all_in && !done_d);
  assign last_b = eos2 && !nb;                  // nothing behind the head: the file's last byte

  always_ff @(posedge clk) begin
    if (rst || restart_req) begin
      wp <= '0; rp <= '0; hd_v <= 1'b0; rd_pend <= 1'b0; ovf <= 1'b0; nb <= 1'b0;
      in_rst <= 1'b1; rst_cnt <= 4'd15; wn <= '0; wd <= '0; dv <= 1'b0;
    end else begin
      if (in_rst) begin rst_cnt <= rst_cnt - 4'd1; if (rst_cnt == 4'd0) in_rst <= 1'b0; end
      if (push) begin if (fifo_full) ovf <= 1'b1; else wp <= wp + 1'b1; end
      nb <= !fifo_empty;                       // (one clock late; see boards/ep2c5/rtl/jtag_stream_core.sv)
      rd_pend <= 1'b0;
      if (!WORDS) begin
        // byte head, offered only when another byte is behind it or the input has ended, so the
        // file's last byte goes in with in_last (as in boards/ep2c5/rtl/jtag_stream_core.sv)
        if (take) hd_v <= 1'b0;
        if (rd_pend) begin hd <= rdata; hd_v <= 1'b1; end
        else if ((!hd_v || take) && !fifo_empty) begin rp <= rp + 1'b1; rd_pend <= 1'b1; end
        dv <= (rd_pend || (hd_v && !take)) && (!fifo_empty || eos2);
      end else begin
        // word head: four bytes, first byte in bits 7:0; the last partial word is zero-padded
        if (take) begin wn <= '0; dv <= 1'b0; wd <= '0; end
        else begin
          if (rd_pend) begin wd[8*wn[1:0] +: 8] <= rdata; wn <= wn + 3'd1; end
          if (!dv && !fifo_empty && ({1'b0, wn} + {3'd0, rd_pend}) < 4'd4) begin
            rp <= rp + 1'b1; rd_pend <= 1'b1;
          end
          if (rd_pend && wn == 3'd3) dv <= 1'b1;
          else if (!dv && !rd_pend && wn != 3'd0 && eos2 && fifo_empty) dv <= 1'b1;   // final partial word
        end
      end
    end
  end

  // ================================================================ dclk domain: the DUT
  logic        px, dfs, dfd;
  logic [15:0] px_x, px_y, w_, h_;
  logic [7:0]  r_, g_, b_;
  logic [12:0] err;
  generate
    if (DUT == 0) begin : g_ours
      logic sof, eol, fs;
      jpeg_decoder #(.FAST(1)) u_dut (
        .clk(dclk), .rst(in_rst), .in_valid(dv), .in_data(hd), .in_last(last_b), .in_ready(dut_ready),
        .out_fmt(2'd0), .px_valid(px), .px_ready(1'b1), .px_x(px_x), .px_y(px_y),
        .px_c0(r_), .px_c1(g_), .px_c2(b_), .px_sof(sof), .px_eol(eol),
        .img_w(w_), .img_h(h_), .frame_start(fs), .frame_done(dfd), .err(err));
    end else if (DUT == 1) begin : g_core_jpeg
      logic idle;
      jpeg_core #(.SUPPORT_WRITABLE_DHT(1)) u_dut (
        .clk_i(dclk), .rst_i(in_rst), .inport_valid_i(dv), .inport_data_i(wd), .inport_strb_i(4'hF),
        .inport_last_i(1'b0), .outport_accept_i(1'b1), .inport_accept_o(dut_ready),
        .outport_valid_o(px), .outport_width_o(w_), .outport_height_o(h_),
        .outport_pixel_x_o(px_x), .outport_pixel_y_o(px_y), .outport_pixel_r_o(r_), .outport_pixel_g_o(g_),
        .outport_pixel_b_o(b_), .idle_o(idle));
      assign err = '0; assign dfd = 1'b0;
    end else begin : g_aq_djpeg
      logic idle, prog, req;
      aq_djpeg u_dut (
        .rst(~in_rst), .clk(dclk), .DataIn(wd), .DataInEnable(dv), .DataInRead(dut_ready), .DataInReq(req),
        .JpegDecodeIdle(idle), .JpegProgressive(prog), .OutReady(1'b1), .OutEnable(px),
        .OutWidth(w_), .OutHeight(h_), .OutPixelX(px_x), .OutPixelY(px_y), .OutR(r_), .OutG(g_), .OutB(b_));
      assign err = '0; assign dfd = 1'b0;
    end
  endgenerate

  // counters (dclk domain: they only move while the DUT's clock runs)
  logic [31:0] chk, cyc, npx, tgt, wdog;
  logic        wdog_hit;
  always_ff @(posedge dclk) begin
    if (in_rst) begin
      chk <= '0; cyc <= '0; npx <= '0; tgt <= '0; wdog <= '0; done_d <= 1'b0; wdog_hit <= 1'b0;
    end else if (!done_d) begin
      cyc <= cyc + 32'd1;
      if (px) begin
        chk <= chk + {px_x[7:0] ^ px_y[7:0], r_, g_, b_};
        npx <= npx + 32'd1;
        if (npx == 32'd0) tgt <= {16'd0, w_} * {16'd0, h_};
      end
      // DUT 0 reports the end of the frame; for the others, the frame ends with its last pixel
      if (DUT == 0 ? dfd : (px && npx != 32'd0 && npx + 32'd1 == tgt)) done_d <= 1'b1;
      // a decoder that stops (stuck input, or nothing more to output) is ended after WATCHDOG of its
      // clocks without a pixel; its clock only runs while input waits or after the input ended
      if (px) wdog <= '0;
      else begin wdog <= wdog + 32'd1; if (wdog == WATCHDOG - 1) begin wdog_hit <= 1'b1; done_d <= 1'b1; end end
    end
  end

  // ================================================================ result (clk domain)
  logic [255:0] res;
  logic [5:0]   ti;                            // byte being sent
  logic         tbusy, tsend;
  logic [9:0]   tsh;
  logic [15:0]  tcnt;
  logic [3:0]   tbit;
  logic         done_c;                        // done_d seen (clk domain, after the restart)
  always_ff @(posedge clk) begin
    if (rst || restart_req) begin done_c <= 1'b0; sent <= 1'b0; tsend <= 1'b0; ti <= '0; tbusy <= 1'b0; uart_tx <= 1'b1; end
    else begin
      sent <= 1'b0;
      if (!done_c && done_d && !in_rst && ps == WAIT) begin
        done_c <= 1'b1; tsend <= 1'b1; ti <= '0;
        res <= {8'h52, 8'h45, 8'h53, DUT[7:0], {5'd0, 1'b1, wdog_hit, ovf}, 24'd0, cyc, chk,
                {3'd0, err}, w_, h_, npx, nrx, 16'd0};
      end
      if (tsend && !tbusy) begin
        if (ti == 6'd32) begin tsend <= 1'b0; sent <= 1'b1; end
        else begin
          tsh <= {1'b1, res[255 - 8*ti -: 8], 1'b0}; tbusy <= 1'b1; tbit <= '0; tcnt <= DIV[15:0] - 16'd1; ti <= ti + 6'd1;
        end
      end
      if (tbusy) begin
        uart_tx <= tsh[0];
        if (tcnt != 16'd0) tcnt <= tcnt - 16'd1;
        else begin
          tcnt <= DIV[15:0] - 16'd1; tsh <= {1'b1, tsh[9:1]}; tbit <= tbit + 4'd1;
          if (tbit == 4'd9) begin tbusy <= 1'b0; uart_tx <= 1'b1; end
        end
      end else uart_tx <= 1'b1;
    end
  end

  // LEDs: heartbeat, frame done, data arriving, overflow
  logic [25:0] hb;
  always_ff @(posedge clk) hb <= hb + 26'd1;
  assign led = {ovf, ps == DATA, done_c, hb[25]};
endmodule
