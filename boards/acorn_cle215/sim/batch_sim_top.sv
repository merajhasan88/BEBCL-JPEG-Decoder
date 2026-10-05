// batch_sim_top.sv - simulation top for uart_batch_core: models each lane's gated clock buffer (a
// 7-series BUFGCE passes a rising edge when its enable was high during the low phase before it).
module batch_sim_top #(parameter int N = 3, parameter int FAST = 2) (
  input  logic       clk,
  input  logic       rst,
  input  logic       uart_rx,
  output logic       uart_tx,
  output logic [3:0] led
);
  logic [N-1:0] run_en, gate;
  initial gate = '1;
  always @(negedge clk) gate <= run_en;
  wire [N-1:0] dclk = {N{clk}} & gate;
  uart_batch_core #(.N(N), .FAST(FAST), .CLK_HZ(16_000_000), .BAUD(2_000_000), .WATCHDOG(1 << 20)) u_core (
    .clk(clk), .rst(rst), .dclk(dclk), .run_en(run_en), .uart_rx(uart_rx), .uart_tx(uart_tx), .led(led));
endmodule
