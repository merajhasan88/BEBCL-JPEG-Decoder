// fpga_jtag_top.sv - EP2C5 board top: a JPEG is streamed in over the USB-Blaster (virtual JTAG)
// and decoded by the fast core at 50 MHz * PLL_MUL / PLL_DIV (95 MHz by default).  The decoder
// clock is gated so that its clock count excludes streaming time (see jtag_stream_core.sv);
// results are read back over JTAG.  Host side: scripts/jtag_decode.py.
// Intel/Altera-specific parts (this file only): altpll, altclkctrl (global clock buffer with a
// glitch-free enable sampled on the falling edge) and sld_virtual_jtag.
// LEDs (active low): [0] toggles after every frame, [1] decoding, [2] decoder error.
module fpga_jtag_top #(
  parameter int PLL_MUL = 19,
  parameter int PLL_DIV = 10,
  parameter int FIFO_AW = 9,
  parameter bit DEBUG   = 1'b0,
  parameter bit CHECKS  = 1'b1
) (
  input  logic       clk,                     // 50 MHz oscillator
  input  logic       key_n,                   // button: reset
  output logic [2:0] led_n
);
  // ---------------------------------------------------------------- core clock
  logic [5:0] pll_clk;
  logic       pll_locked, cclk;
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

  // ---------------------------------------------------------------- reset
  logic [1:0]  key_sync;
  logic [15:0] por_cnt;
  logic        rst;
  always_ff @(posedge cclk) begin
    key_sync <= {key_sync[0], key_n};
    if (!pll_locked) por_cnt <= '0;
    else if (por_cnt != 16'hFFFF) por_cnt <= por_cnt + 16'd1;
    rst <= (por_cnt != 16'hFFFF) | ~key_sync[1];
  end

  // ---------------------------------------------------------------- gated decoder clock
  logic run_en, dclk;
  altclkctrl #(
    .clock_type("Global Clock"), .ena_register_mode("falling edge"),
    .number_of_clocks(4), .width_clkselect(2)
  ) u_gate (
    .inclk({3'b000, cclk}), .clkselect(2'b00), .ena(run_en), .outclk(dclk));

  // ---------------------------------------------------------------- virtual JTAG
  logic       tck, tdi, tdo, v_cdr, v_sdr, v_udr;
  logic [1:0] ir;
  sld_virtual_jtag #(
    .sld_auto_instance_index("YES"), .sld_instance_index(0), .sld_ir_width(2)
  ) u_vjtag (
    .tck(tck), .tdi(tdi), .tdo(tdo), .ir_in(ir), .ir_out(2'b00),
    .virtual_state_cdr(v_cdr), .virtual_state_sdr(v_sdr), .virtual_state_udr(v_udr),
    .virtual_state_e1dr(), .virtual_state_pdr(), .virtual_state_e2dr(), .virtual_state_cir(),
    .virtual_state_uir(), .tms(), .jtag_state_tlr(), .jtag_state_rti(), .jtag_state_sdrs(),
    .jtag_state_cdr(), .jtag_state_sdr(), .jtag_state_e1dr(), .jtag_state_pdr(), .jtag_state_e2dr(),
    .jtag_state_udr(), .jtag_state_sirs(), .jtag_state_cir(), .jtag_state_sir(), .jtag_state_e1ir(),
    .jtag_state_pir(), .jtag_state_e2ir(), .jtag_state_uir());

  // ---------------------------------------------------------------- stream + decoder
  logic [2:0] led;
  jtag_stream_core #(.FIFO_AW(FIFO_AW), .DEBUG(DEBUG), .CHECKS(CHECKS)) u_core (
    .clk(cclk), .rst(rst), .dclk(dclk), .run_en(run_en),
    .tck(tck), .tdi(tdi), .ir(ir), .v_cdr(v_cdr), .v_sdr(v_sdr), .v_udr(v_udr), .tdo(tdo),
    .led(led));
  assign led_n = ~led;
endmodule
