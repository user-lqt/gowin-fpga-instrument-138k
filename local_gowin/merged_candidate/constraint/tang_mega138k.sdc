//=============================================================================
// tang_mega138k.sdc —— 时序约束
//
// 归属：成员 C 独占维护。
//
// 时钟结构（见 rtl/system/clock_gen.v）：
//   i_clk_in  50 MHz 输入参考   （板载晶振，管脚 V22）
//   clk_audio 12.28814 MHz 音频域（PLL CLKOUT0）
//   clk_sys   103.571 MHz 系统域（PLL CLKOUT1）
//
// 显式声明音频 PLL 时钟，供后续 DAC 转发时钟约束使用。
// 未使用的系统 PLL 输出可被综合裁剪。
//=============================================================================

//-----------------------------------------------------------------------------
// 1. 输入参考时钟：板载 50 MHz 晶振（V22），周期 20 ns
//    换晶振时必须同步修改这里与 clock_gen.v 的分频参数
//-----------------------------------------------------------------------------
create_clock -name clk_in -period 20.000 [get_ports {i_clk_in}]
# Declare the PLL clock before using it as another generated clock's source.
# PLL ratio: 50 MHz * 29 / (2 * 59) = 12.2881356 MHz.
create_generated_clock -name clk_audio -source [get_ports {i_clk_in}] -multiply_by 29 -divide_by 118 [get_pins {u_clock_gen/pll_inst/CLKOUT0}]

//-----------------------------------------------------------------------------
// 2. 异步输入
//    S2 复位键相对时钟异步，且其 BANK 为 1.5V
//-----------------------------------------------------------------------------
set_false_path -from [get_ports {i_rst_n}]

//-----------------------------------------------------------------------------
// 3. PT8211 输出：DIN/WS 相对转发 BCK 的上升沿约束
//-----------------------------------------------------------------------------
# PT8211 captures DIN/WS on rising BCK. The 20 ns input setup/hold budget
# is a conservative board allowance; PT8211 v1.6 does not specify tSU/tHD.
create_generated_clock -name dac_bck -source [get_pins {u_clock_gen/pll_inst/CLKOUT0}] -divide_by 8 [get_ports {o_hp_bck}]
set_output_delay -clock dac_bck -max 20.000 [get_ports {o_hp_ws o_hp_din}]
set_output_delay -clock dac_bck -min -20.000 [get_ports {o_hp_ws o_hp_din}]
set_false_path -to [get_ports {o_pa_en}]

// 指示灯为低速信号，不需要时序约束
set_false_path -to [get_ports {o_led o_locked}]

//-----------------------------------------------------------------------------
// 待办
//   实物验收仍需检查音质、输入至 DAC 延迟及长期稳定性。
//-----------------------------------------------------------------------------
