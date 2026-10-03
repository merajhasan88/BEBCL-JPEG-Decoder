# Full-path timing reports (cell / interconnect split) of the paths that limited the fast core
# at 100 MHz; edit the -from/-to patterns as needed.  Run: quartus_sta -t ../sta_detail.tcl
project_open jpeg_fpga
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_timing -setup -npaths 1 -detail full_path -from [get_registers {*u_win|wcnt[1]}] -to [get_keepers {*u_lut*portb_address_reg1}] -file detail_lut.txt
report_timing -setup -npaths 1 -detail full_path -from [get_registers {*u_idct|y1[5][16]}] -to [get_keepers {*g_wbank[0].u_ws*porta_datain_reg10}] -file detail_y1.txt
report_timing -setup -npaths 1 -detail full_path -to [get_registers {*u_idct|x2s13[16]}] -file detail_x2.txt
report_timing -setup -npaths 1 -detail full_path -from [get_keepers {*u_lut*}] -to [get_registers {*u_hd|*}] -file detail_sym.txt
delete_timing_netlist
project_close
