# Lists the worst setup path per (from, to) pair of the opened project into sta_paths.txt as
# "slack|from|to" (3000 pairs).  Run inside a project directory after a compile:
#   quartus_sta -t ../sta_paths.tcl
project_open jpeg_fpga
create_timing_netlist -model slow
read_sdc
update_timing_netlist
set paths [get_timing_paths -setup -npaths 3000 -nworst 1 -pairs_only]
set fh [open "sta_paths.txt" w]
foreach_in_collection p $paths {
  set s [get_path_info $p -slack]
  set from [get_node_info -name [get_path_info $p -from]]
  set to [get_node_info -name [get_path_info $p -to]]
  puts $fh "$s|$from|$to"
}
close $fh
delete_timing_netlist
project_close
