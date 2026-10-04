// bench_lane.sv - one decoder lane of the batched harness (uart_batch_core.sv): the input FIFO, the
// head that offers the next byte to the decoder, the decoder (this library's jpeg_decoder, FAST=1 or
// FAST=2, MCU order, RGB) and its counters. The logic is that of uart_bench_core.sv for DUT 0 / DUT 3,
// which stays the single-decoder harness. Vendor-neutral; the board top supplies one gated clock per
// lane.
//
// Clocks:
//   clk   free-running core clock (FIFO, control)
//   dclk  this lane's clock: clk gated by run_en (a glitch-free clock buffer such as a Xilinx 7-series
//         BUFGCE). run_en is high only while the decoder's next input byte is waiting (or during reset,
//         or after the file's last byte until the frame is done), so `cyc` is the decode time with an
//         ideal input, independent of the serial speed and of the other lanes.
module bench_lane #(
  parameter int FAST     = 2,                   // 1: one pixel per clock, 2: four pixels per beat
  parameter int FIFO_AW  = 12,                  // 4 KB input FIFO
  parameter int WATCHDOG = 1 << 26
) (
  input  logic        clk,
  input  logic        rst,                      // clk domain, synchronous
  input  logic        dclk,                     // clk gated by run_en
  output logic        run_en,
  input  logic        restart,                  // clk-domain pulse: a new file (empties the FIFO, resets the decoder)
  input  logic        push,                     // clk domain: the next byte of the file
  input  logic [7:0]  push_b,
  input  logic        eos,                      // clk domain: the file's last byte was pushed (rises with that
                                                // push; cleared by restart)
  output logic        res_v,                    // the result below is final (frame done or watchdog)
  output logic        ovf,                      // FIFO overflow
  output logic        wdog_hit,                 // no pixel for WATCHDOG decoder clocks
  output logic [31:0] cyc,                      // decoder clocks
  output logic [31:0] chk,                      // sum over pixels of {(x ^ y)[7:0], R, G, B} mod 2^32
  output logic [31:0] npx,                      // pixels
  output logic [12:0] err,
  output logic [15:0] w_, h_
);
  // ================================================================ input FIFO and the decoder's head
  logic [FIFO_AW:0] wp, rp;
  logic [7:0]       rdata, hd;
  logic             hd_v, rd_pend, in_rst, nb, fifo_empty, fifo_full;
  logic [3:0]       rst_cnt;
  assign fifo_empty = (wp == rp);
  assign fifo_full  = (wp[FIFO_AW] != rp[FIFO_AW]) && (wp[FIFO_AW-1:0] == rp[FIFO_AW-1:0]);
  jpeg_sdp_ram #(.WIDTH(8), .DEPTH_LOG2(FIFO_AW)) u_fifo (
    .clk(clk), .we(push && !fifo_full), .waddr(wp[FIFO_AW-1:0]), .wdata(push_b),
    .raddr(rp[FIFO_AW-1:0]), .rdata(rdata));

  logic dv, take, dut_ready, last_b, eos1, eos2, done_d, all_in;
  // eos rises with the last byte's push: eos2 is it two clocks later, when the FIFO has it
  always_ff @(posedge clk) begin eos1 <= eos && !restart; eos2 <= eos1 && eos && !restart; end
  assign take   = run_en && dv && dut_ready;   // the decoder takes its input at this (dclk = clk) edge
  assign all_in = eos2 && fifo_empty && !rd_pend && !hd_v && !dv;
  // the clock enable: reset, input waiting, or input finished and the frame still running (a 7-series
  // BUFGCE passes a rising edge when its enable is high just before it)
  assign run_en = in_rst || dv || (all_in && !done_d);
  assign last_b = eos2 && !nb;                  // nothing behind the head: the file's last byte
  assign res_v  = done_d && !in_rst;

  always_ff @(posedge clk) begin
    if (rst || restart) begin
      wp <= '0; rp <= '0; hd_v <= 1'b0; rd_pend <= 1'b0; ovf <= 1'b0; nb <= 1'b0;
      in_rst <= 1'b1; rst_cnt <= 4'd15; dv <= 1'b0;
    end else begin
      if (in_rst) begin rst_cnt <= rst_cnt - 4'd1; if (rst_cnt == 4'd0) in_rst <= 1'b0; end
      if (push) begin if (fifo_full) ovf <= 1'b1; else wp <= wp + 1'b1; end
      nb <= !fifo_empty;                       // (one clock late; see boards/ep2c5/rtl/jtag_stream_core.sv)
      rd_pend <= 1'b0;
      // the head byte is offered only when another byte is behind it or the input has ended, so the
      // file's last byte goes in with in_last
      if (take) hd_v <= 1'b0;
      if (rd_pend) begin hd <= rdata; hd_v <= 1'b1; end
      else if ((!hd_v || take) && !fifo_empty) begin rp <= rp + 1'b1; rd_pend <= 1'b1; end
      dv <= (rd_pend || (hd_v && !take)) && (!fifo_empty || eos2);
    end
  end

  // ================================================================ dclk domain: the decoder
  logic        px, dfd, sof, eol, fs;
  logic [15:0] px_x, px_y;
  logic [2:0]  pn;                              // pixels in the beat
  localparam int NP = (FAST == 2) ? 4 : 1;
  logic [8*NP-1:0] r4, g4, b4;                  // pixel i in bits 8i+7..8i
  jpeg_decoder #(.FAST(FAST)) u_dut (
    .clk(dclk), .rst(in_rst), .in_valid(dv), .in_data(hd), .in_last(last_b), .in_ready(dut_ready),
    .out_fmt(2'd0), .px_valid(px), .px_ready(1'b1), .px_x(px_x), .px_y(px_y), .px_n(pn),
    .px_c0(r4), .px_c1(g4), .px_c2(b4), .px_sof(sof), .px_eol(eol),
    .img_w(w_), .img_h(h_), .frame_start(fs), .frame_done(dfd), .err(err));

  // counters (they only move while the lane's clock runs). The frame ends with frame_done; the
  // checksum pipeline then drains for 3 clocks, which are not counted.
  logic [31:0] wdog;
  logic        fin;
  logic [1:0]  fin_d;
  always_ff @(posedge dclk) begin
    if (in_rst) begin
      cyc <= '0; npx <= '0; wdog <= '0; done_d <= 1'b0; wdog_hit <= 1'b0; fin <= 1'b0; fin_d <= '0;
    end else if (!done_d) begin
      if (!fin) cyc <= cyc + 32'd1;
      if (px) npx <= npx + {29'd0, pn};
      if (dfd) fin <= 1'b1;
      fin_d <= {fin_d[0], fin};
      if (fin_d[1]) done_d <= 1'b1;
      // a decoder that stops (stuck input, or nothing more to output) is ended after WATCHDOG of its
      // clocks without a pixel; its clock only runs while input waits or after the input ended
      if (px) wdog <= '0;
      else begin wdog <= wdog + 32'd1; if (wdog == WATCHDOG - 1) begin wdog_hit <= 1'b1; done_d <= 1'b1; end end
    end
  end
  // checksum of the pixels of a beat, {(x ^ y)[7:0], R, G, B} each, in a pipeline (2 clocks)
  logic        cv1, cv2;
  logic [31:0] ct [0:3];
  logic [31:0] csa, csb;
  always_ff @(posedge dclk) begin : g_chk
    integer i;
    logic [7:0] xi;
    cv1 <= px && !in_rst && !done_d;
    for (i = 0; i < 4; i = i + 1) begin
      xi = px_x[7:0] + i[7:0];
      ct[i] <= (i < NP && i < pn) ? {xi ^ px_y[7:0], r4[8*(i % NP) +: 8], g4[8*(i % NP) +: 8], b4[8*(i % NP) +: 8]} : 32'd0;
    end
    cv2 <= cv1; csa <= ct[0] + ct[1]; csb <= ct[2] + ct[3];
    if (in_rst) chk <= '0;
    else if (cv2) chk <= chk + csa + csb;
  end
endmodule
