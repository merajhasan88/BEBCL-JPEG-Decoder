create_clock -name clk -period 20.000 [get_ports clk]
create_clock -name altera_reserved_tck -period 100.000 [get_ports altera_reserved_tck]
set_clock_groups -asynchronous -group {altera_reserved_tck}
derive_pll_clocks
derive_clock_uncertainty
set_false_path -from [get_ports key_n]
set_false_path -to [get_ports {led_n[*]}]
