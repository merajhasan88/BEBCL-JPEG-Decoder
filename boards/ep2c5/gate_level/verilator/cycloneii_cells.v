// cycloneii_cells.v - independent, zero-delay behavioural models of the Cyclone II cells that
// appear in the Quartus post-fit netlists of this project, for zero-delay gate-level
// simulation.  Written for this project from the cell descriptions in the Cyclone II Device
// Handbook; not derived from the vendor's simulation library.  Only the ports and parameters
// used by the netlists are modelled (an unknown parameter is reported by Verilator by name).
//
//   cycloneii_lcell_comb  4-input LUT with carry chain (normal and arithmetic mode)
//   cycloneii_lcell_ff    LE register: async clear, sync clear, sync load, clock enable
//   cycloneii_ram_block   M4K block: dual_port (A writes, B reads) and rom (A reads) modes
//   cycloneii_mac_mult    18x18 multiplier with optional input registers
//   cycloneii_mac_out     multiplier output stage with optional output register
//   cycloneii_clkctrl     global clock buffer with clock select and (registered) enable
//   cycloneii_io_in/_out  input and output pads (prepare_netlist.py splits the netlist's
//                         cycloneii_io cells by their operation_mode)
// Power-up state of every register is 0.  devclrn/devpor (device-wide clear) are accepted and
// ignored: the designs here reset themselves synchronously.
`timescale 1 ps / 1 ps

// ------------------------------------------------------------------ logic element: LUT + carry
// The 16-bit mask is indexed by {d, c, b, a}.  In arithmetic mode the LUT acts as two 3-input
// LUTs: combout uses the upper half (datad is tied high by the fitter) with c = cin, and the carry
// out uses the lower half with c = cin.
module cycloneii_lcell_comb (dataa, datab, datac, datad, cin, combout, cout);
  input  dataa, datab, datac, datad, cin;
  output combout, cout;
  parameter [15:0] lut_mask = 16'h0000;
  parameter sum_lutc_input = "datac";                 // "datac" or "cin"
  parameter lpm_type = "cycloneii_lcell_comb";
  wire c_in = (sum_lutc_input == "cin") ? cin : datac;
  assign combout = lut_mask[{datad, c_in, datab, dataa}];
  assign cout    = lut_mask[{1'b0, cin, datab, dataa}];
endmodule

// ------------------------------------------------------------------ logic element register
module cycloneii_lcell_ff (datain, clk, aclr, sclr, sload, sdata, ena, devclrn, devpor, regout);
  input  datain, clk, aclr, sclr, sload, sdata, ena, devclrn, devpor;
  output regout;
  parameter x_on_violation = "on";
  parameter lpm_type = "cycloneii_lcell_ff";
  reg q;
  initial q = 1'b0;
  always @(posedge clk or posedge aclr)
    if (aclr)     q <= 1'b0;
    else if (ena) q <= sclr ? 1'b0 : (sload ? sdata : datain);
  assign regout = q;
endmodule

// ------------------------------------------------------------------ M4K memory block
// Port A (clock 0): write port in dual_port mode, read port in rom mode.  Port B (address clock
// selectable, normally clock 0): read port.  Address, data and write enable are registered on
// the port's clock (when its clock enable is high and address stall is low); a read returns the
// contents at that edge, so a simultaneous write to the same word returns the old word
// ("old" mixed-port behaviour).  Data outputs can be registered once more (data_out_clock).
// Initial contents come from mem_init1:mem_init0 (init_file_layout = port_a, word i at bits
// [i*width +: width]).
module cycloneii_ram_block (portadatain, portaaddr, portawe, portbdatain, portbaddr, portbrewe,
                            clk0, clk1, ena0, ena1, clr0, clr1, portabyteenamasks,
                            portbbyteenamasks, portaaddrstall, portbaddrstall, devclrn, devpor,
                            portadataout, portbdataout);
  parameter operation_mode = "rom";                    // "rom" or "dual_port"
  parameter ram_block_type = "M4K";
  parameter logical_ram_name = "ram";
  parameter init_file = "none";
  parameter init_file_layout = "none";
  parameter data_interleave_width_in_bits = 1;
  parameter data_interleave_offset_in_bits = 1;
  parameter mixed_port_feed_through_mode = "old";
  parameter safe_write = "err_on_2clk";
  parameter mem_init0 = 0;
  parameter mem_init1 = 0;
  parameter port_a_data_width = 1;
  parameter port_a_address_width = 1;
  parameter port_a_first_address = 0;
  parameter port_a_last_address = 0;
  parameter port_a_first_bit_number = 0;
  parameter port_a_logical_ram_depth = 0;
  parameter port_a_logical_ram_width = 0;
  parameter port_a_data_out_clock = "none";           // "none", "clock0", "clock1"
  parameter port_a_data_out_clear = "none";
  parameter port_a_data_in_clear = "none";
  parameter port_a_address_clear = "none";
  parameter port_a_write_enable_clock = "none";
  parameter port_a_write_enable_clear = "none";
  parameter port_a_byte_enable_clock = "none";
  parameter port_a_byte_enable_clear = "none";
  parameter port_a_byte_enable_mask_width = 1;
  parameter port_b_data_width = 1;
  parameter port_b_address_width = 1;
  parameter port_b_first_address = 0;
  parameter port_b_last_address = 0;
  parameter port_b_first_bit_number = 0;
  parameter port_b_logical_ram_depth = 0;
  parameter port_b_logical_ram_width = 0;
  parameter port_b_address_clock = "clock0";          // "clock0" or "clock1"
  parameter port_b_read_enable_write_enable_clock = "clock0";
  parameter port_b_data_out_clock = "none";           // "none", "clock0", "clock1"
  parameter port_b_data_out_clear = "none";
  parameter port_b_data_in_clock = "clock1";
  parameter port_b_data_in_clear = "none";
  parameter port_b_address_clear = "none";
  parameter port_b_read_enable_write_enable_clear = "none";
  parameter port_b_byte_enable_clock = "none";
  parameter port_b_byte_enable_clear = "none";
  parameter port_b_byte_enable_mask_width = 1;
  parameter power_up_uninitialized = "false";
  parameter lpm_type = "cycloneii_ram_block";
  parameter lpm_hint = "unused";
  parameter connectivity_checking = "off";

  input  [port_a_data_width-1:0]    portadatain;
  input  [port_a_address_width-1:0] portaaddr;
  input                             portawe;
  input  [port_b_data_width-1:0]    portbdatain;
  input  [port_b_address_width-1:0] portbaddr;
  input                             portbrewe;
  input  clk0, clk1, ena0, ena1, clr0, clr1;
  input  [port_a_byte_enable_mask_width-1:0] portabyteenamasks;
  input  [port_b_byte_enable_mask_width-1:0] portbbyteenamasks;
  input  portaaddrstall, portbaddrstall, devclrn, devpor;
  output [port_a_data_width-1:0]    portadataout;
  output [port_b_data_width-1:0]    portbdataout;

  localparam WORDS = 1 << port_a_address_width;
  localparam INIT  = {mem_init1, mem_init0};
  localparam INIT_BITS = $bits(INIT);
  reg [port_a_data_width-1:0] mem [0:WORDS-1];
  integer i, j;
  initial begin
    for (i = 0; i < WORDS; i = i + 1) mem[i] = {port_a_data_width{1'b0}};
    if (init_file_layout != "none")
      for (i = 0; i < WORDS; i = i + 1)
        for (j = 0; j < port_a_data_width; j = j + 1)
          if (i * port_a_data_width + j < INIT_BITS) mem[i][j] = INIT[i * port_a_data_width + j];
  end

  // port A
  reg [port_a_address_width-1:0] a_hold;
  reg [port_a_data_width-1:0]    a_rd, a_out;
  initial begin a_hold = 0; a_rd = 0; a_out = 0; end
  wire [port_a_address_width-1:0] a_addr = portaaddrstall ? a_hold : portaaddr;
  always @(posedge clk0) if (ena0) begin
    a_hold <= a_addr;
    a_rd   <= mem[a_addr];
    if (operation_mode != "rom" && portawe) mem[a_addr] <= portadatain;
  end
  wire a_out_clk = (port_a_data_out_clock == "clock1") ? clk1 : clk0;
  wire a_out_ena = (port_a_data_out_clock == "clock1") ? ena1 : ena0;
  always @(posedge a_out_clk) if (a_out_ena) a_out <= a_rd;
  assign portadataout = (port_a_data_out_clock == "none") ? a_rd : a_out;

  // port B (read)
  wire b_clk = (port_b_address_clock == "clock1") ? clk1 : clk0;
  wire b_ena = (port_b_address_clock == "clock1") ? ena1 : ena0;
  reg [port_b_address_width-1:0] b_hold;
  reg [port_b_data_width-1:0]    b_rd, b_out;
  initial begin b_hold = 0; b_rd = 0; b_out = 0; end
  wire [port_b_address_width-1:0] b_addr = portbaddrstall ? b_hold : portbaddr;
  always @(posedge b_clk) if (b_ena && portbrewe) begin
    b_hold <= b_addr;
    b_rd   <= mem[b_addr];
  end
  wire b_out_clk = (port_b_data_out_clock == "clock1") ? clk1 : clk0;
  wire b_out_ena = (port_b_data_out_clock == "clock1") ? ena1 : ena0;
  always @(posedge b_out_clk) if (b_out_ena) b_out <= b_rd;
  assign portbdataout = (port_b_data_out_clock == "none") ? b_rd : b_out;
endmodule

// ------------------------------------------------------------------ 18x18 multiplier
module cycloneii_mac_mult (dataa, datab, signa, signb, clk, aclr, ena, dataout, devclrn, devpor);
  parameter dataa_width = 18;
  parameter datab_width = 18;
  parameter dataa_clock = "none";                     // "none" or "0": input register
  parameter datab_clock = "none";
  parameter signa_clock = "none";
  parameter signb_clock = "none";
  parameter dataa_clear = "none";
  parameter datab_clear = "none";
  parameter signa_clear = "none";
  parameter signb_clear = "none";
  parameter signa_internally_grounded = "false";
  parameter signb_internally_grounded = "false";
  parameter dataout_width = dataa_width + datab_width;
  parameter lpm_type = "cycloneii_mac_mult";
  input  [dataa_width-1:0] dataa;
  input  [datab_width-1:0] datab;
  input  signa, signb, clk, aclr, ena, devclrn, devpor;
  output [dataout_width-1:0] dataout;
  reg [dataa_width-1:0] ra; reg [datab_width-1:0] rb; reg rsa, rsb;
  initial begin ra = 0; rb = 0; rsa = 0; rsb = 0; end
  always @(posedge clk or posedge aclr)
    if (aclr)     begin ra <= 0; rb <= 0; rsa <= 0; rsb <= 0; end
    else if (ena) begin ra <= dataa; rb <= datab; rsa <= signa; rsb <= signb; end
  wire [dataa_width-1:0] a  = (dataa_clock == "none") ? dataa : ra;
  wire [datab_width-1:0] b  = (datab_clock == "none") ? datab : rb;
  wire                   sa = (signa_clock == "none") ? signa : rsa;
  wire                   sb = (signb_clock == "none") ? signb : rsb;
  // extend each operand to 40 bits as signed or unsigned, multiply, keep the low bits
  wire signed [39:0] ax = sa ? $signed({{(40-dataa_width){a[dataa_width-1]}}, a}) : $signed({{(40-dataa_width){1'b0}}, a});
  wire signed [39:0] bx = sb ? $signed({{(40-datab_width){b[datab_width-1]}}, b}) : $signed({{(40-datab_width){1'b0}}, b});
  wire signed [79:0] prod = ax * bx;
  assign dataout = prod[dataout_width-1:0];
endmodule

// ------------------------------------------------------------------ multiplier output stage
module cycloneii_mac_out (dataa, clk, aclr, ena, dataout, devclrn, devpor);
  parameter dataa_width = 36;
  parameter output_clock = "none";                    // "none" or "0": output register
  parameter output_clear = "none";
  parameter dataout_width = dataa_width;
  parameter lpm_type = "cycloneii_mac_out";
  input  [dataa_width-1:0] dataa;
  input  clk, aclr, ena, devclrn, devpor;
  output [dataout_width-1:0] dataout;
  reg [dataa_width-1:0] q;
  initial q = 0;
  always @(posedge clk or posedge aclr)
    if (aclr)     q <= 0;
    else if (ena) q <= dataa;
  assign dataout = (output_clock == "none") ? dataa : q;
endmodule

// ------------------------------------------------------------------ global clock buffer
// outclk = the selected input clock, gated by ena.  ena_register_mode "falling edge" samples
// ena on the falling edge of the selected clock (glitch-free gating); "none" uses it directly.
module cycloneii_clkctrl (inclk, clkselect, ena, devclrn, devpor, outclk);
  parameter clock_type = "global clock";
  parameter ena_register_mode = "falling edge";
  parameter lpm_type = "cycloneii_clkctrl";
  input  [3:0] inclk;
  input  [1:0] clkselect;
  input  ena, devclrn, devpor;
  output outclk;
  wire clk_sel = inclk[clkselect];
  reg  ena_q;
  initial ena_q = 1'b1;
  always @(negedge clk_sel) ena_q <= ena;
  assign outclk = clk_sel & ((ena_register_mode == "none") ? ena : ena_q);
endmodule

// ------------------------------------------------------------------ pads
// Zero-delay pads: an input pad passes padio to combout, an output pad drives datain onto padio.
module cycloneii_io_in (datain, oe, outclk, outclkena, inclk, inclkena, areset, sreset, devclrn,
                        devpor, devoe, linkin, differentialin, differentialout, padio, combout,
                        regout, linkout);
  parameter operation_mode = "input";
  parameter open_drain_output = "false";
  parameter bus_hold = "false";
  parameter output_register_mode = "none";
  parameter output_async_reset = "none";
  parameter output_sync_reset = "none";
  parameter output_power_up = "low";
  parameter tie_off_output_clock_enable = "false";
  parameter oe_register_mode = "none";
  parameter oe_async_reset = "none";
  parameter oe_sync_reset = "none";
  parameter oe_power_up = "low";
  parameter tie_off_oe_clock_enable = "false";
  parameter input_register_mode = "none";
  parameter input_async_reset = "none";
  parameter input_sync_reset = "none";
  parameter input_power_up = "low";
  parameter use_differential_input = "false";
  parameter lpm_type = "cycloneii_io";
  input  datain, oe, outclk, outclkena, inclk, inclkena, areset, sreset, devclrn, devpor, devoe;
  input  linkin, differentialin, padio;
  output differentialout, combout, regout, linkout;
  assign combout = padio;
  assign regout = 1'b0;
  assign differentialout = 1'b0;
  assign linkout = 1'b0;
endmodule

module cycloneii_io_out (datain, oe, outclk, outclkena, inclk, inclkena, areset, sreset, devclrn,
                         devpor, devoe, linkin, differentialin, differentialout, padio, combout,
                         regout, linkout);
  parameter operation_mode = "output";
  parameter open_drain_output = "false";
  parameter bus_hold = "false";
  parameter output_register_mode = "none";
  parameter output_async_reset = "none";
  parameter output_sync_reset = "none";
  parameter output_power_up = "low";
  parameter tie_off_output_clock_enable = "false";
  parameter oe_register_mode = "none";
  parameter oe_async_reset = "none";
  parameter oe_sync_reset = "none";
  parameter oe_power_up = "low";
  parameter tie_off_oe_clock_enable = "false";
  parameter input_register_mode = "none";
  parameter input_async_reset = "none";
  parameter input_sync_reset = "none";
  parameter input_power_up = "low";
  parameter use_differential_input = "false";
  parameter lpm_type = "cycloneii_io";
  input  datain, oe, outclk, outclkena, inclk, inclkena, areset, sreset, devclrn, devpor, devoe;
  input  linkin, differentialin;
  output padio, differentialout, combout, regout, linkout;
  assign padio = datain;
  assign combout = 1'b0;
  assign regout = 1'b0;
  assign differentialout = 1'b0;
  assign linkout = 1'b0;
endmodule
