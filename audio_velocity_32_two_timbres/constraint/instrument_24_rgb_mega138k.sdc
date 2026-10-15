create_clock -name clk_in -period 20.000 [get_ports {i_clk_in}]
create_generated_clock -name clk_audio -source [get_ports {i_clk_in}] -multiply_by 29 -divide_by 118 [get_pins {u_clock_gen/pll_inst/CLKOUT0}]
create_generated_clock -name clk_pixel -source [get_ports {i_clk_in}] -multiply_by 2 -divide_by 3 [get_pins {u_pixel_clock/pll_inst/CLKOUT0}]
create_generated_clock -name dac_bck -source [get_pins {u_clock_gen/pll_inst/CLKOUT0}] -divide_by 4 [get_ports {o_hp_bck}]
create_generated_clock -name lcd_clock -add -source [get_pins {u_pixel_clock/pll_inst/CLKOUT0}] -divide_by 1 [get_ports {lcd_sc_clk}]
set_clock_groups -asynchronous -group [get_clocks {clk_audio dac_bck}] -group [get_clocks {clk_pixel lcd_clock}]
# PCM5102A DIN/LRCK setup and hold budget at BCK rising edge (ns).
set_output_delay -clock dac_bck -max 10.000 [get_ports {o_hp_ws o_hp_din}]
set_output_delay -clock dac_bck -min -10.000 [get_ports {o_hp_ws o_hp_din}]
# Preliminary panel budget: verify setup/hold against the actual LCD datasheet.
set_output_delay -clock lcd_clock -max 5.000 [get_ports {lcd_sc_hs lcd_sc_vs lcd_sc_de lcd_r_out[*] lcd_g_out[*] lcd_b_out[*]}]
set_output_delay -clock lcd_clock -min -1.000 [get_ports {lcd_sc_hs lcd_sc_vs lcd_sc_de lcd_r_out[*] lcd_g_out[*] lcd_b_out[*]}]
set_false_path -from [get_ports {i_rst_n col_in[*] enc_a enc_b enc_sw_n enc2_a enc2_b enc2_sw_n}]
set_false_path -to [get_ports {o_pa_en o_led o_locked row_out[*]}]
