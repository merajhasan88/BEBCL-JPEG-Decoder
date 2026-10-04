// jtag_stream_core.sv - feeds jpeg_decoder with a JPEG streamed over JTAG and measures the
// decoder's own clock count, independent of how fast the bytes arrive.
//
// Clocks:
//   clk   free-running core clock (FIFO, control)
//   dclk  the decoder clock: clk gated by run_en (a glitch-free clock buffer that samples its
//         enable on the falling edge of clk, e.g. the Cyclone II global clock control block).
//         run_en is high only while the decoder's next input byte is waiting in `hd` (or during
//         reset, or after the end of the stream once every byte has been consumed).  The head byte
//         is offered only once another byte is behind it or the stream has ended, so the file's
//         last byte goes in with in_last (a file cut short still ends with frame_done).  At every
//         dclk edge the decoder sees in_valid = 1 - exactly the situation of a simulation with an
//         ideal source.  `cyc` counts dclk edges, i.e. the decoder's clocks with streaming time
//         removed; the host measures the wall time.
//   tck   JTAG clock of a virtual-JTAG style instance (tck, tdi, tdo, ir, capture/shift/update
//         DR states); the wrapper supplies it (sld_virtual_jtag on Intel/Altera devices).
//
// JTAG instructions (2-bit virtual IR):
//   1 DATA      the DR bits after the 16-bit sync word 16'hA5C3 (LSB first) are bytes for the
//               input FIFO, 8 bits each, LSB first.  The virtual-JTAG hub shifts some header
//               bits (7 with Quartus 13.0sp1 and one node) into the instance before the payload;
//               hunting for the sync word makes the byte alignment independent of their number.
//   2 RESULT    capture {checksum[31:0], clocks[31:0]} and shift it out (LSB first); with
//               DEBUG = 1 instead {20'd0, shift clocks of the last DR scan[11:0], bytes received[7:0],
//               bytes taken by the decoder[7:0], first byte, last byte} (since the last restart)
//   3 CONTROL   capture the status word below and shift it out; the 64 bits shifted in are
//               applied at Update-DR: bit 0 = restart (reset decoder, counters, FIFO; a
//               toggle-free edge: the host sends 1 then 0), bit 1 = end of stream
//   status word = {8'hA5, frames[7:0], 3'd0, err[12:0], 16'd0,         (err as at the last frame_done:
//                  bytes after an image, e.g. trailing data after EOI, raise errors of their own)
//                  8'd0, 3'd0, empty, eos, busy, half, overflow}
// The checksum is fpga_top's: sum over all pixels of {x[7:0]^y[7:0], R, G, B} (32 bits).
module jtag_stream_core #(
  parameter int FIFO_AW = 9,                 // input FIFO: 2^FIFO_AW bytes
  parameter bit DEBUG   = 1'b0,              // RESULT returns the debug word (see above)
  parameter bit CHECKS  = 1'b1               // header/table validation (jpeg_decoder)
) (
  input  logic        clk,
  input  logic        rst,                   // clk domain, synchronous, power-on
  input  logic        dclk,                  // clk gated by run_en (see above)
  output logic        run_en,
  // JTAG
  input  logic        tck,
  input  logic        tdi,
  input  logic [1:0]  ir,
  input  logic        v_cdr, v_sdr, v_udr,
  output logic        tdo,
  // status
  output logic [2:0]  led                    // [0] frame toggle, [1] decoding, [2] error
);
  import jpeg_pkg::*;

  // ================================================================ TCK domain
  logic [63:0] dr;
  logic [2:0]  bitc;
  logic [15:0] win;                          // last 16 bits, while hunting for the sync word
  logic        synced;
  localparam logic [15:0] SYNC = 16'hA5C3;   // odd: leading zero bits can never complete it
  logic [7:0]  tck_byte;
  logic        tck_tog, ctl_restart, ctl_eos;
  logic [63:0] cap_result, cap_status, cap_debug;   // (sampled from the other domains at Capture-DR)
  logic [11:0] sdr_cnt, sdr_last;
  always_ff @(posedge tck) begin
    if (v_cdr) begin
      bitc <= '0; sdr_cnt <= '0; synced <= 1'b0; win <= '0;
      if (ir == 2'd2) dr <= cap_result;
      if (ir == 2'd3) dr <= cap_status;
    end
    if (v_udr) sdr_last <= sdr_cnt;
    if (v_sdr) begin
      sdr_cnt <= sdr_cnt + 12'd1;
      dr <= {tdi, dr[63:1]};
      if (ir == 2'd1) begin
        if (!synced) begin
          win <= {tdi, win[15:1]};
          if ({tdi, win[15:1]} == SYNC) begin synced <= 1'b1; bitc <= '0; end
        end else begin
          bitc <= bitc + 3'd1;
          if (bitc == 3'd7) begin tck_byte <= {tdi, dr[63:57]}; tck_tog <= ~tck_tog; end
        end
      end
    end
    if (v_udr && ir == 2'd3) begin ctl_restart <= dr[0]; ctl_eos <= dr[1]; end
  end
  assign tdo = dr[0];
  initial begin tck_tog = 1'b0; ctl_restart = 1'b0; ctl_eos = 1'b0; bitc = '0; sdr_cnt = '0; sdr_last = '0; synced = 1'b0; win = '0; end

  // ================================================================ clk domain: FIFO and gate
  logic [2:0]  tog_s, rst_s, eos_s;          // synchronisers
  logic        push, restart_req, eos;
  always_ff @(posedge clk) begin
    tog_s <= {tog_s[1:0], tck_tog};
    rst_s <= {rst_s[1:0], ctl_restart};
    eos_s <= {eos_s[1:0], ctl_eos};
  end
  assign push        = tog_s[2] ^ tog_s[1];
  assign restart_req = rst_s[1] & ~rst_s[2];  // rising edge of the restart bit
  assign eos         = eos_s[2];

  logic [FIFO_AW:0]   wp, rp;                // one extra bit: full / empty
  logic [7:0]         rdata, hd;
  logic               hd_v, rd_pend, ovf, in_rst, run_q, take, dec_in_ready;
  logic               nb, dec_v;               // a byte is behind the head; head offered (both registered)
  logic               eos_idle;              // end of stream and every byte consumed (registered)
  logic               dec_v_n, eos_idle_n, in_rst_n, run_en_r;   // next values; run_en as one register
  logic [3:0]         rst_cnt;
  logic               fifo_empty, fifo_full;
  assign fifo_empty = (wp == rp);
  assign fifo_full  = (wp[FIFO_AW] != rp[FIFO_AW]) && (wp[FIFO_AW-1:0] == rp[FIFO_AW-1:0]);
  // the input RAM: written with bytes from JTAG, read into the head register
  jpeg_sdp_ram #(.WIDTH(8), .DEPTH_LOG2(FIFO_AW)) u_fifo (
    .clk(clk), .we(push && !fifo_full), .waddr(wp[FIFO_AW-1:0]), .wdata(tck_byte),
    .raddr(rp[FIFO_AW-1:0]), .rdata(rdata));
  // (tck_byte crosses from the TCK domain without a synchroniser: it is stable for 8 TCK periods
  //  after its toggle, and the toggle takes 2-3 clk cycles to arrive)
  logic [FIFO_AW:0] level;
  assign level = wp - rp;

  // the enable as the clock buffer sees it: sampled on the falling edge of clk
  always_ff @(negedge clk) run_q <= run_en;
  // the decoder takes `hd` at a dclk edge (= a clk edge with run_q) when it is ready
  assign take   = run_q && dec_v && dec_in_ready;
  // The clock buffer samples run_en half a clock after the rising edge, so run_en is a register of
  // its own (= in_rst || dec_v || eos_idle, from their next values): no logic on that half-cycle path
  assign run_en     = run_en_r;
  assign dec_v_n    = (rd_pend || (hd_v && !take)) && (!fifo_empty || eos);
  assign eos_idle_n = eos && fifo_empty && !rd_pend && !push;
  assign in_rst_n   = in_rst && (rst_cnt != 4'd0);

  logic [7:0]  rx_cnt, tk_cnt;
  logic [7:0]  first_rx, last_rx;
  always_ff @(posedge clk) begin
    if (rst || restart_req) begin rx_cnt <= '0; tk_cnt <= '0; first_rx <= '0; last_rx <= '0; end
    else begin
      if (push) begin rx_cnt <= rx_cnt + 8'd1; last_rx <= tck_byte; if (rx_cnt == 8'd0) first_rx <= tck_byte; end
      if (take) tk_cnt <= tk_cnt + 8'd1;
    end
  end
  assign cap_debug = {20'd0, sdr_last, rx_cnt, tk_cnt, first_rx, last_rx};

  always_ff @(posedge clk) begin
    if (rst || restart_req) begin
      wp <= '0; rp <= '0; hd_v <= 1'b0; rd_pend <= 1'b0; ovf <= 1'b0; in_rst <= 1'b1; rst_cnt <= 4'd15;
      eos_idle <= 1'b0; nb <= 1'b0; dec_v <= 1'b0; run_en_r <= 1'b1;
    end else begin
      eos_idle <= eos_idle_n;
      run_en_r <= in_rst_n || dec_v_n || eos_idle_n;
      nb       <= !fifo_empty;                 // (one clock late; the FIFO only empties by a read into
                                               //  the head, which leaves hd_v low for that clock)
      // dec_v = hd_v && (nb || eos) of the next clock, as a register (it feeds the clock enable
      // half a clock later and the decoder's input logic); eos is used one clock late (harmless)
      dec_v    <= dec_v_n;
      if (in_rst) begin rst_cnt <= rst_cnt - 4'd1; if (rst_cnt == 4'd0) in_rst <= 1'b0; end
      if (push) begin
        if (fifo_full) ovf <= 1'b1;
        else wp <= wp + 1'b1;
      end
      // head register: refilled from the RAM (1 clock read latency) when empty or just taken
      rd_pend <= 1'b0;
      if (take) hd_v <= 1'b0;
      if (rd_pend) begin hd <= rdata; hd_v <= 1'b1; end
      else if ((!hd_v || take) && !fifo_empty) begin rp <= rp + 1'b1; rd_pend <= 1'b1; end
    end
  end
  // (the RAM is read at address rp and delivers mem[rp] one clock later, when rd_pend is set)

  // ================================================================ dclk domain: the decoder
  logic        px_valid, frame_start, frame_done, px_sof, px_eol;
  logic [15:0] px_x, px_y, img_w, img_h;
  logic [7:0]  c0, c1, c2;
  logic [12:0] err;
  jpeg_decoder #(.FAST(1), .CHECKS(CHECKS)) u_dec (
    .clk(dclk), .rst(in_rst),
    .in_valid(dec_v), .in_data(hd), .in_ready(dec_in_ready),
    .in_last(eos && !nb),                      // end of stream and nothing behind: the file's last byte .out_fmt(FMT_RGB),
    .px_valid(px_valid), .px_ready(1'b1), .px_x(px_x), .px_y(px_y),
    .px_c0(c0), .px_c1(c1), .px_c2(c2), .px_sof(px_sof), .px_eol(px_eol),
    .img_w(img_w), .img_h(img_h), .frame_start(frame_start), .frame_done(frame_done), .err(err));

  logic [31:0] chk, cyc;
  logic [7:0]  frames;
  logic [12:0] err_frame;                    // err at the last frame_done
  logic        counting, decoding;
  always_ff @(posedge dclk) begin
    if (in_rst) begin
      chk <= '0; cyc <= '0; counting <= 1'b1; decoding <= 1'b0;
    end else begin
      if (counting) cyc <= cyc + 32'd1;
      if (frame_start) decoding <= 1'b1;
      if (frame_done) begin counting <= 1'b0; decoding <= 1'b0; frames <= frames + 8'd1; err_frame <= err; end
      if (px_valid) chk <= chk + {px_x[7:0] ^ px_y[7:0], c0, c1, c2};
    end
  end
  initial frames = '0;

  // snapshots for JTAG (read by the host after the frame is done, when they are stable)
  assign cap_result = DEBUG ? cap_debug : {chk, cyc};
  assign cap_status = {8'hA5, frames, 3'd0, err_frame, 16'd0, 8'd0, 3'd0,           // (bits 31:16 were img_w: unused, saves LEs)
                       fifo_empty, eos, decoding, level[FIFO_AW] | level[FIFO_AW-1], ovf};
  assign led = {err_frame != 13'd0, decoding, frames[0]};
endmodule
