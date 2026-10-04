# Vivado non-project build of acorn_top for one decoder:
#   vivado -mode batch -source build.tcl -tclargs <DUT 0|1|2> <CLKOUT_DIV> <out_dir>
# DUT 0 needs ../../rtl; DUT 1 and 2 need the other decoders' sources in
# ../../bench/others/third_party (bench/others/fetch.sh).  Part: XC7A200T-2 (the Acorn CLE-215+ is -3; -2
# timing is the safe side for either grade).
if {[info exists ::env(VIVADO_THREADS)]} { set_param general.maxThreads $::env(VIVADO_THREADS) }
set dut [lindex $argv 0]; set div [lindex $argv 1]; set out [lindex $argv 2]
set here [file dirname [file normalize [info script]]]
set rtl  [file normalize $here/../../rtl]
set tp   [file normalize $here/../../bench/others/third_party]
file mkdir $out
read_verilog -sv $rtl/jpeg_sdp_ram.sv
if {$dut == 0} {
  foreach f {jpeg_pkg jpeg_blockram jpeg_parser jpeg_bitreader jpeg_coefdec jpeg_idct jpeg_ycc2rgb
             jpeg_pixgen jpeg_raster jpeg_dec_small jpeg_bitwin jpeg_huffdec jpeg_idct_fast jpeg_mcuout
             jpeg_raster_fast jpeg_dec_fast jpeg_decoder} { read_verilog -sv $rtl/$f.sv }
} elseif {$dut == 1} {
  read_verilog [glob $tp/core_jpeg/src_v/*.v]
} else {
  read_verilog [glob $tp/legacy_jpeg_decoder/core/*.v]
}
read_verilog -sv [list $here/uart_bench_core.sv $here/acorn_top.sv]
read_xdc $here/acorn.xdc
synth_design -top acorn_top -part xc7a200tfbg484-2 -generic DUT=$dut -generic CLKOUT_DIV=$div
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -max_paths 10 -file $out/timing.rpt
report_utilization -file $out/utilization.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $out/utilization_hier.rpt
write_bitstream -force $out/acorn_dut${dut}_div${div}.bit
