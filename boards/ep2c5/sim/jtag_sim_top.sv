// jtag_sim_top.sv - simulation top for jtag_stream_core: models the glitch-free clock buffer
// (enable sampled on the falling edge of clk) that fpga_jtag_top gets from the device.
module jtag_sim_top (
  input  logic       clk,
  input  logic       rst,
  input  logic       tck,
  input  logic       tdi,
  input  logic [1:0] ir,
  input  logic       v_cdr, v_sdr, v_udr,
  output logic       tdo,
  output logic [2:0] led,
  output logic       dclk_en                 // for the testbench: the gate's current state
);
  logic run_en, gate;
  initial gate = 1'b1;
  always @(negedge clk) gate <= run_en;
  wire dclk = clk & gate;
  assign dclk_en = gate;
  jtag_stream_core u_core (
    .clk(clk), .rst(rst), .dclk(dclk), .run_en(run_en),
    .tck(tck), .tdi(tdi), .ir(ir), .v_cdr(v_cdr), .v_sdr(v_sdr), .v_udr(v_udr), .tdo(tdo), .led(led));
endmodule
