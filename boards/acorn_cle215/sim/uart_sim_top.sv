// uart_sim_top.sv - simulation top for uart_bench_core: models the gated clock buffer (a 7-series
// BUFGCE passes a rising edge when its enable was high during the low phase before it).
module uart_sim_top #(parameter int DUT = 0) (
  input  logic       clk,
  input  logic       rst,
  input  logic       uart_rx,
  output logic       uart_tx,
  output logic [3:0] led,
  output logic       dclk_en
);
  logic run_en, gate;
  initial gate = 1'b1;
  always @(negedge clk) gate <= run_en;
  wire dclk = clk & gate;
  assign dclk_en = gate;
  uart_bench_core #(.DUT(DUT), .CLK_HZ(16_000_000), .BAUD(2_000_000), .WATCHDOG(1 << 20)) u_core (
    .clk(clk), .rst(rst), .dclk(dclk), .run_en(run_en), .uart_rx(uart_rx), .uart_tx(uart_tx), .led(led));
endmodule
