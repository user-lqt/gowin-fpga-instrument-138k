// Diagnostic wrapper adds one hierarchy level around the proven clock path.
create_clock -name clk_in -period 20.000 [get_ports {i_clk_in}]
create_generated_clock -name clk_audio -source [get_ports {i_clk_in}] -multiply_by 29 -divide_by 118 [get_pins {instrument/u_clock_gen/pll_inst/CLKOUT0}]
set_false_path -from [get_ports {i_rst_n}]
create_generated_clock -name dac_bck -source [get_pins {instrument/u_clock_gen/pll_inst/CLKOUT0}] -divide_by 8 [get_ports {o_hp_bck}]
set_output_delay -clock dac_bck -max 20.000 [get_ports {o_hp_ws o_hp_din}]
set_output_delay -clock dac_bck -min -20.000 [get_ports {o_hp_ws o_hp_din}]
set_false_path -to [get_ports {o_pa_en o_led o_locked oled_scl oled_sda}]
set_false_path -from [get_ports {col_in[0] col_in[1] col_in[2] col_in[3] enc_a enc_b enc_sw_n oled_scl oled_sda}]
