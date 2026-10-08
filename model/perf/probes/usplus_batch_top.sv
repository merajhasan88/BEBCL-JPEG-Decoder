// usplus_batch_top.sv - the batched harness (boards/acorn_cle215/uart_batch_core.sv: N decoder lanes) on
// an UltraScale+ FPGA, out of context, for usplus_timing.tcl. As acorn_batch_top.sv without the board's
// clock input and MMCM: the clock port drives the core clock's BUFG and one BUFGCE per lane. A timing
// probe only (no pins, no bitstream): it estimates the decoders' clock on AWS F2's VU47P from a Kintex
// UltraScale+ part that the free Vivado licence covers.
module usplus_batch_top #(
  parameter int N      = 15,
  parameter int FAST   = 2,
  parameter int CLK_HZ = 250_000_000,
  parameter int BAUD   = 1_000_000
) (
  input  logic       clk_in,
  input  logic       uart_rx,
  output logic       uart_tx,
  output logic [3:0] led
);
  logic         clk;
  logic [N-1:0] run_en, dclk;
  BUFG u_clk (.I(clk_in), .O(clk));
  genvar gi;
  generate
    for (gi = 0; gi < N; gi = gi + 1) begin : g_gate
      BUFGCE #(.SIM_DEVICE("ULTRASCALE_PLUS")) u_gate (.I(clk_in), .CE(run_en[gi]), .O(dclk[gi]));
    end
  endgenerate

  // power-on reset for 2^16 clocks
  logic [16:0] por = '0;
  logic        rst;
  always_ff @(posedge clk) begin
    if (!por[16]) por <= por + 17'd1;
    rst <= !por[16];
  end

  uart_batch_core #(.N(N), .FAST(FAST), .CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_core (
    .clk(clk), .rst(rst), .dclk(dclk), .run_en(run_en), .uart_rx(uart_rx), .uart_tx(uart_tx), .led(led));
endmodule
