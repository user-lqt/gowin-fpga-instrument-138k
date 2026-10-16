create_clock -name clk_in -period 20.000 [get_ports {i_clk_in}]
set_false_path -from [get_ports {i_rst_n oled_scl oled_sda}]
set_false_path -to [get_ports {o_led o_locked oled_scl oled_sda}]
