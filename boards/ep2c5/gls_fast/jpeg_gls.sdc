create_clock -name clk -period 20.000 [get_ports clk]
derive_clock_uncertainty
set_false_path -from [get_ports key_n]
set_false_path -to [get_ports {led_n[*] uart_tx}]
