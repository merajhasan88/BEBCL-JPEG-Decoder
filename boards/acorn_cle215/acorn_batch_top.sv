// acorn_batch_top.sv - SQRL Acorn CLE-215+ (Xilinx Artix-7 XC7A200T, as on fpgas.online): N JPEG
// decoder lanes (uart_batch_core.sv) measured over the Raspberry Pi's UART, all decoding at the same
// time. As acorn_top.sv, with one BUFGCE per lane gating that lane's clock. An MMCM may drive only the
// 16 global clock buffers of its half of the device: the core clock and the N lane gates take N + 1 of
// them (the MMCM's feedback is internal, without a buffer), so N is at most 15.
module acorn_batch_top #(
  parameter int N          = 15,              // lanes (at most 15, see above)
  parameter int FAST       = 2,               // 2: wide core, 1: single (one pixel per clock)
  parameter int CLKOUT_DIV = 8,               // core clock = 1200 MHz / CLKOUT_DIV (8 -> 150 MHz)
  parameter int BAUD       = 1_000_000
) (
  input  logic       clk200_p,
  input  logic       clk200_n,
  input  logic       uart_rx,                 // from the Pi (GPIO14, TXD)
  output logic       uart_tx,                 // to the Pi (GPIO15, RXD)
  output logic [3:0] led
);
  localparam int CLK_HZ = 1_200_000_000 / CLKOUT_DIV;
  logic         clk200, fb, clk_m, clk, locked;
  logic [N-1:0] run_en, dclk;
  IBUFDS u_ibuf (.I(clk200_p), .IB(clk200_n), .O(clk200));
  MMCME2_BASE #(
    .CLKIN1_PERIOD(5.0), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(6.0), .CLKOUT0_DIVIDE_F(CLKOUT_DIV)
  ) u_mmcm (
    .CLKIN1(clk200), .CLKFBIN(fb), .CLKFBOUT(fb), .CLKOUT0(clk_m), .LOCKED(locked),   // internal feedback
    .RST(1'b0), .PWRDWN(1'b0),
    .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(),
    .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6());
  BUFG u_clk (.I(clk_m), .O(clk));
  genvar gi;
  generate
    for (gi = 0; gi < N; gi = gi + 1) begin : g_gate
      BUFGCE #(.SIM_DEVICE("7SERIES")) u_gate (.I(clk_m), .CE(run_en[gi]), .O(dclk[gi]));
    end
  endgenerate

  // power-on reset: held until the MMCM has locked, then for 2^16 clocks
  logic [16:0] por = '0;
  logic        rst;
  always_ff @(posedge clk) begin
    if (!locked) por <= '0; else if (!por[16]) por <= por + 17'd1;
    rst <= !por[16];
  end

  uart_batch_core #(.N(N), .FAST(FAST), .CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_core (
    .clk(clk), .rst(rst), .dclk(dclk), .run_en(run_en), .uart_rx(uart_rx), .uart_tx(uart_tx), .led(led));
endmodule
