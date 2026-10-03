// fpga_top.sv - demo top for the Cyclone II EP2C5T144C8 mini board.
//
//   JPEG in on-chip ROM  ->  jpeg_decoder  ->  pixel serialiser / benchmark report  ->  UART TX (8N1)
//
// Serial protocol (all big-endian):
//   BENCH = 0 (pixel stream):
//     frame header : A5 5A 'J' 'P' 'G' W_hi W_lo H_hi H_lo
//     per pixel    : X_hi X_lo Y_hi Y_lo C0 C1 C2        (R,G,B / Y,Cb,Cr / Y,128,128 by OUT_FMT;
//                                                        MCU order, or raster order if RASTER_OUT)
//     frame trailer: 'E' 'N' 'D'
//     boards/ep2c5/scripts/uart_capture.py reassembles the pixels into a PPM on the PC.
//   BENCH = 1 (speed measurement): the decoder runs at full speed, every pixel is accepted the
//     clock it is offered and only folded into the checksum; afterwards
//     A5 5A 'B' 'N' 'C' W_hi W_lo H_hi H_lo  CLOCKS[31:0]  CHK[31:0]  0 ERR[10:8] ERR[7:0]  'E' 'N' 'D'
//     where CLOCKS counts core clocks from the decoder leaving reset (first JPEG byte) to
//     frame_done.  boards/ep2c5/scripts/uart_bench.py prints it as time and Mpixel/s.
// The frame is then re-decoded and re-sent after ~1.5 s, forever.
//
// Self-check: a 32-bit checksum of all pixels, CHK = sum over pixels of
// {(x ^ y)[7:0], c0, c1, c2} (mod 2^32, order independent), is compared with EXPECTED_CHK,
// which scripts/pnm_checksum.py computes from the golden image (djpeg, or Pillow for the
// FANCY_UPSAMPLE + CC_TURBO profile).
// LEDs (active low): led_n[0] toggles with every frame, led_n[1] ON while the last frame's checksum matched
// (the frame is re-decoded every 1.5 s), led_n[2] ON on any decoder error.
//
// Clock: PLL_MUL = 0 runs everything from the 50 MHz input.  PLL_MUL > 0 runs the design from a
// Cyclone II PLL (altpll) at 50 MHz * PLL_MUL / PLL_DIV; CLK_HZ must then be set to that
// frequency (UART divider and timers).  The PLL is the only vendor-specific part of the design.
module fpga_top #(
  // decoder build options (see jpeg_decoder)
  parameter bit    FAST           = 1'b0,
  parameter bit    RASTER_OUT     = 1'b0,
  parameter int    ROWBUF_BYTES   = 9216,
  parameter bit    FANCY_UPSAMPLE = 1'b0,
  parameter bit    CC_TURBO       = 1'b0,
  parameter bit    RGB_OUT        = 1'b1,
  parameter bit    CHECKS         = 1'b1,           // header/table validation (jpeg_decoder)
  parameter int    OUT_FMT        = 0,              // 0 RGB, 1 YCbCr, 2 Y
  parameter bit    BENCH          = 1'b0,           // 1: full-speed decode + clock-count report
  parameter int    PLL_MUL        = 0,              // 0: no PLL
  parameter int    PLL_DIV        = 1,
  parameter int    CLK_HZ    = 50_000_000,          // core clock
  parameter int    BAUD      = 115200,
  parameter int    ROM_ADDR_BITS = 10,
  parameter int    ROM_LENGTH    = 719,
  parameter        ROM_HEX       = "jpeg_rom.hex",
  parameter logic [31:0] EXPECTED_CHK = 32'h0,     // golden pixel checksum (0 = no check)
  parameter int    RESTART_DELAY = 75_000_000,      // clocks between frames (1.5 s at 50 MHz)
  parameter int    WATCHDOG      = 25_000_000       // give up on a frame after 0.5 s without a pixel
) (
  input  logic       clk,        // 50 MHz
  input  logic       key_n,      // push button, active low = reset
  output logic [2:0] led_n,
  output logic       uart_tx
);
  // ---------------------------------------------------------------- clock
  logic cclk;                     // core clock
  logic pll_locked;
  generate
    if (PLL_MUL != 0) begin : g_pll
      logic [5:0] pll_clk;
      altpll #(
        .intended_device_family("Cyclone II"), .lpm_type("altpll"), .operation_mode("NORMAL"),
        .inclk0_input_frequency(20000), .compensate_clock("CLK0"),
        .clk0_multiply_by(PLL_MUL), .clk0_divide_by(PLL_DIV), .clk0_duty_cycle(50), .clk0_phase_shift("0"),
        .port_inclk0("PORT_USED"), .port_clk0("PORT_USED"), .port_locked("PORT_USED"),
        .port_areset("PORT_UNUSED"), .port_pllena("PORT_UNUSED"), .port_inclk1("PORT_UNUSED"),
        .port_clk1("PORT_UNUSED"), .port_clk2("PORT_UNUSED")
      ) u_pll (
        .inclk({1'b0, clk}), .clk(pll_clk), .locked(pll_locked));
      assign cclk = pll_clk[0];
    end else begin : g_nopll
      assign cclk = clk;
      assign pll_locked = 1'b1;
    end
  endgenerate

  // ---------------------------------------------------------------- reset
  logic [1:0]  key_sync;
  logic [15:0] por_cnt;
  logic        rst, soft_rst, core_rst;
  always_ff @(posedge cclk) begin
    key_sync <= {key_sync[0], key_n};
    if (!pll_locked) por_cnt <= '0;
    else if (por_cnt != 16'hFFFF) por_cnt <= por_cnt + 16'd1;
    rst <= (por_cnt != 16'hFFFF) | ~key_sync[1];     // registered: it reaches thousands of registers
  end
  assign core_rst = rst | soft_rst;

  // ---------------------------------------------------------------- ROM -> skid buffer -> decoder
  logic       rom_valid, rom_ready, rom_done, rom_restart;
  logic [7:0] rom_data;
  jpeg_rom #(.ADDR_BITS(ROM_ADDR_BITS), .LENGTH(ROM_LENGTH), .HEX_FILE(ROM_HEX)) u_rom (
    .clk(cclk), .rst(rst), .restart(rom_restart),
    .out_valid(rom_valid), .out_data(rom_data), .out_ready(rom_ready), .done(rom_done));

  // 2-entry buffer with registered outputs in both directions: keeps the ROM out of the parser's
  // logic paths (and the parser's ready out of the ROM's)
  logic       sk_v0, sk_v1, dec_valid, dec_ready;
  logic [7:0] sk_b0, sk_b1;
  assign rom_ready = ~sk_v1;
  assign dec_valid = sk_v0;
  always_ff @(posedge cclk) begin
    if (rst || rom_restart) begin
      sk_v0 <= 1'b0; sk_v1 <= 1'b0; sk_b0 <= '0; sk_b1 <= '0;
    end else begin
      case ({rom_valid & rom_ready, dec_valid & dec_ready})
        2'b10: if (!sk_v0) begin sk_v0 <= 1'b1; sk_b0 <= rom_data; end
               else        begin sk_v1 <= 1'b1; sk_b1 <= rom_data; end
        2'b01: begin sk_v0 <= sk_v1; sk_b0 <= sk_b1; sk_v1 <= 1'b0; end
        2'b11: if (sk_v1) begin sk_b0 <= sk_b1; sk_b1 <= rom_data; end
               else       begin sk_b0 <= rom_data; end
        default: ;
      endcase
    end
  end

  logic        px_valid, px_ready, frame_start, frame_done, px_sof, px_eol;
  logic [15:0] px_x, px_y, img_w, img_h;
  logic [7:0]  px_c0, px_c1, px_c2;
  logic [12:0] err;
  localparam logic [1:0] FMT = OUT_FMT;
  jpeg_decoder #(.FAST(FAST), .RASTER_OUT(RASTER_OUT), .ROWBUF_BYTES(ROWBUF_BYTES), .FANCY_UPSAMPLE(FANCY_UPSAMPLE),
                 .CC_TURBO(CC_TURBO), .RGB_OUT(RGB_OUT), .CHECKS(CHECKS)) u_dec (
    .clk(cclk), .rst(core_rst),
    .in_valid(dec_valid), .in_data(sk_b0), .in_last(1'b0), .in_ready(dec_ready), .out_fmt(FMT),
    .px_valid(px_valid), .px_ready(px_ready), .px_x(px_x), .px_y(px_y),
    .px_c0(px_c0), .px_c1(px_c1), .px_c2(px_c2), .px_sof(px_sof), .px_eol(px_eol),
    .img_w(img_w), .img_h(img_h), .frame_start(frame_start), .frame_done(frame_done), .err(err));

  // ---------------------------------------------------------------- UART
  // The serialiser's byte (a wide multiplexer) is registered before the UART: ob_* holds the byte
  // being offered, `accept` = it was taken.
  logic       ut_valid, ut_ready, ob_valid, accept;
  logic [7:0] ut_data, ob_data;
  assign accept = ob_valid & ut_ready;
  uart_tx #(.CLK_DIV(CLK_HZ / BAUD)) u_uart (
    .clk(cclk), .rst(rst), .in_valid(ob_valid), .in_data(ob_data), .in_ready(ut_ready), .tx(uart_tx));
  always_ff @(posedge cclk) begin
    if (rst || accept) ob_valid <= 1'b0;
    else if (!ob_valid && ut_valid) begin ob_valid <= 1'b1; ob_data <= ut_data; end
  end

  // ---------------------------------------------------------------- serialiser
  typedef enum logic [2:0] { S_WAIT, S_HDR, S_RUN, S_PIX, S_TRAIL, S_DELAY } state_t;
  state_t      state;
  logic [3:0]  idx;                       // byte index inside a header / pixel / trailer
  logic [55:0] pix;                       // latched pixel record
  logic [79:0] rec;                       // record being sent (BENCH: clocks, checksum, errors - stable by then)
  logic [71:0] hdr;
  logic [23:0] trailer;
  logic [26:0] tmr;                       // S_DELAY: time since the frame; S_WAIT/S_RUN: time since the last pixel
  logic        done_seen;
  logic        frame_led;
  logic [31:0] chk;                       // running pixel checksum
  logic        chk_ok;                    // last completed frame matched EXPECTED_CHK
  logic [31:0] cyc;                       // BENCH: clocks since the decoder left reset
  localparam logic [3:0] PIX_LAST = BENCH ? 4'd9 : 4'd6;

  assign px_ready = (state == S_RUN);     // accept a pixel only when idle in the run state
  assign hdr      = BENCH ? {8'hA5, 8'h5A, 8'h42, 8'h4E, 8'h43, img_w, img_h}    // "BNC"
                          : {8'hA5, 8'h5A, 8'h4A, 8'h50, 8'h47, img_w, img_h};   // "JPG"
  assign trailer  = {8'h45, 8'h4E, 8'h44};
  assign rec      = BENCH ? {cyc, chk, 3'd0, err} : {24'd0, pix};

  always_comb begin
    ut_valid = 1'b0; ut_data = 8'h00;
    case (state)
      S_HDR:   begin ut_valid = 1'b1; ut_data = hdr[8*(4'd8 - idx) +: 8]; end
      S_PIX:   begin ut_valid = 1'b1; ut_data = rec[8*(PIX_LAST - idx) +: 8]; end
      S_TRAIL: begin ut_valid = 1'b1; ut_data = trailer[8*(4'd2 - idx) +: 8]; end
      default: ;
    endcase
  end

  always_ff @(posedge cclk) begin
    soft_rst <= 1'b0; rom_restart <= 1'b0;
    if (rst) begin
      state <= S_WAIT; idx <= '0; pix <= '0; tmr <= '0; done_seen <= 1'b0; frame_led <= 1'b0;
      chk <= '0; chk_ok <= 1'b0; cyc <= '0;
    end else begin
      if (frame_done) done_seen <= 1'b1;
      if (frame_start) chk <= '0;
      else if (px_valid && px_ready) chk <= chk + {px_x[7:0] ^ px_y[7:0], px_c0, px_c1, px_c2};
      if (BENCH && (state == S_WAIT || state == S_RUN) && !done_seen) cyc <= cyc + 32'd1;
      // one timer: restart delay in S_DELAY, watchdog in S_WAIT/S_RUN (a truncated/corrupt ROM
      // image could leave the decoder waiting for bytes forever)
      if (state == S_DELAY || ((state == S_WAIT || state == S_RUN) && !px_valid && !frame_start)) tmr <= tmr + 27'd1;
      else tmr <= '0;
      if ((state == S_WAIT || state == S_RUN) && tmr == WATCHDOG[26:0]) begin
        soft_rst <= 1'b1; rom_restart <= 1'b1; state <= S_WAIT; tmr <= '0; cyc <= '0; done_seen <= 1'b0;
      end else
      case (state)
        S_WAIT: if (frame_start) begin
          idx <= '0; done_seen <= 1'b0;
          state <= BENCH ? S_RUN : S_HDR;
        end
        S_HDR: if (accept) begin
          if (idx == 4'd8) begin idx <= '0; state <= BENCH ? S_PIX : S_RUN; end
          else idx <= idx + 4'd1;
        end
        S_RUN: begin
          if (BENCH) begin
            if (done_seen || frame_done) begin            // report: clocks, checksum, errors
              idx <= '0; state <= S_HDR;
            end
          end else if (px_valid) begin
            pix <= {px_x, px_y, px_c0, px_c1, px_c2}; idx <= '0; state <= S_PIX;
          end else if (done_seen || frame_done) begin
            idx <= '0; state <= S_TRAIL;
          end
        end
        S_PIX: if (accept) begin
          if (idx == PIX_LAST) begin idx <= '0; state <= BENCH ? S_TRAIL : S_RUN; end
          else idx <= idx + 4'd1;
        end
        S_TRAIL: if (accept) begin
          if (idx == 4'd2) begin
            idx <= '0; state <= S_DELAY; tmr <= '0; frame_led <= ~frame_led;
            chk_ok <= (chk == EXPECTED_CHK) && (err == 13'd0);
          end
          else idx <= idx + 4'd1;
        end
        S_DELAY: begin
          if (tmr == RESTART_DELAY[26:0]) begin
            soft_rst <= 1'b1; rom_restart <= 1'b1; state <= S_WAIT; cyc <= '0; done_seen <= 1'b0;
          end
        end
        default: state <= S_WAIT;
      endcase
    end
  end

  // ---------------------------------------------------------------- LEDs
  // led_n[0] toggles with every frame sent (~1.5 s apart): a heartbeat that also shows the decoder
  // finishing frames (a separate free-running heartbeat counter cost 26 logic elements)
  assign led_n[0] = ~frame_led;
  assign led_n[1] = ~chk_ok;
  assign led_n[2] = ~(|err);
endmodule
