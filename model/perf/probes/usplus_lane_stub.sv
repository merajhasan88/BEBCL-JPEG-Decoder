// usplus_lane_stub.sv - bench_lane (boards/acorn_cle215/bench_lane.sv) as a black box, for the bottom-up
// synthesis in usplus_timing.tcl: the top is synthesized with these empty lanes, then each is filled with
// the netlist of one lane synthesized on its own. The ports must match bench_lane.sv.
(* black_box *)
module bench_lane #(
  parameter int FAST     = 2,
  parameter int FIFO_AW  = 12,
  parameter int WATCHDOG = 1 << 26
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        dclk,
  output logic        run_en,
  input  logic        restart,
  input  logic        push,
  input  logic [7:0]  push_b,
  input  logic        eos,
  output logic        res_v,
  output logic        ovf,
  output logic        wdog_hit,
  output logic [31:0] cyc,
  output logic [31:0] chk,
  output logic [31:0] npx,
  output logic [12:0] err,
  output logic [15:0] w_, h_
);
endmodule
