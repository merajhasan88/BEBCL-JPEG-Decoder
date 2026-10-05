# Vivado non-project build of acorn_batch_top (N decoder lanes, all decoding at the same time):
#   vivado -mode batch -source build_batch.tcl -tclargs <lanes> <FAST 1|2> <CLKOUT_DIV> <out_dir> [stage]
# stage: synth (synthesis -> post_synth.dcp), place (post_synth.dcp -> opt, place, phys_opt ->
# post_place.dcp), route (post_place.dcp -> route, phys_opt, reports, bitstream) or all (default, one
# process). Run as separate processes, the stages need less memory than one process: a 15-lane build
# in one process grew to 9.7 GB resident by the end of placement. Environment: VIVADO_THREADS,
# VIVADO_EFFORT=high (as build.tcl), VIVADO_PART (default xc7a200tfbg484-2; the Acorn CLE-215+ itself
# is a -3).
if {[info exists ::env(VIVADO_THREADS)]} { set_param general.maxThreads $::env(VIVADO_THREADS) }
set n [lindex $argv 0]; set fast [lindex $argv 1]; set div [lindex $argv 2]; set out [lindex $argv 3]
set stage [lindex $argv 4]; if {$stage eq ""} { set stage all }
set part xc7a200tfbg484-2
if {[info exists ::env(VIVADO_PART)]} { set part $::env(VIVADO_PART) }
set high [expr {[info exists ::env(VIVADO_EFFORT)] && $::env(VIVADO_EFFORT) eq "high"}]
set here [file dirname [file normalize [info script]]]
set rtl  [file normalize $here/../../rtl]
file mkdir $out

if {$stage eq "synth" || $stage eq "all"} {
  # the decoder's sources in compile order (rtl/files.f)
  set fh [open $rtl/files.f]
  foreach line [split [read $fh] "\n"] {
    set f [string trim $line]
    if {$f ne "" && [string index $f 0] ne "/"} { read_verilog -sv $rtl/$f }
  }
  close $fh
  read_verilog -sv [list $here/bench_lane.sv $here/uart_batch_core.sv $here/acorn_batch_top.sv]
  read_xdc $here/acorn.xdc
  synth_design -top acorn_batch_top -part $part -generic N=$n -generic FAST=$fast -generic CLKOUT_DIV=$div
  report_utilization -file $out/utilization_synth.rpt
  if {$stage eq "synth"} { write_checkpoint -force $out/post_synth.dcp; return }
}
if {$stage eq "place" || $stage eq "all"} {
  if {$stage eq "place"} { open_checkpoint $out/post_synth.dcp }
  opt_design
  if {$high} {
    place_design -directive ExtraTimingOpt
    phys_opt_design -directive AggressiveExplore
  } else {
    place_design
    phys_opt_design
  }
  report_timing_summary -max_paths 10 -file $out/timing_place.rpt
  if {$stage eq "place"} { write_checkpoint -force $out/post_place.dcp; return }
}
if {$stage eq "route" || $stage eq "all"} {
  if {$stage eq "route"} { open_checkpoint $out/post_place.dcp }
  if {$high} {
    route_design -directive AggressiveExplore
    phys_opt_design -directive AggressiveExplore
  } else {
    route_design
  }
  report_timing_summary -max_paths 10 -file $out/timing.rpt
  report_timing -max_paths 1000 -nworst 1 -unique_pins -slack_lesser_than 0 -file $out/failing.rpt
  report_clock_utilization -file $out/clock_utilization.rpt
  write_checkpoint -force $out/post_route.dcp
  report_utilization -file $out/utilization.rpt
  report_utilization -hierarchical -hierarchical_depth 3 -file $out/utilization_hier.rpt
  write_bitstream -force $out/acorn_batch_n${n}_f${fast}_div${div}.bit
}
