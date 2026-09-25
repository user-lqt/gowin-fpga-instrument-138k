#=============================================================================
# build.tcl —— 综合 + 布局布线 + 生成 bitstream
#
# 用法（Windows）：
#   "E:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" tools\build.tcl
#
# 注意：脚本内路径全部用绝对路径，因为 gw_sh 的工作目录是"当前目录"。
#=============================================================================

set ROOT    {E:/GowinProjects/synth_top}
set DEVICE  {GW5AST-LV138PG484AC1/I0}
# 器件版本：2026-09-24 实物丝印核对为 C 版（官方例程均为 B，勿照抄）
set DEVVER  {C}

cd $ROOT

create_project -name synth_top -dir $ROOT/project -pn $DEVICE -device_version $DEVVER -force

# ---- 源文件 ----
add_file $ROOT/rtl/common/reset_sync.v
add_file $ROOT/rtl/system/clock_gen.v
add_file $ROOT/rtl/system/sample_scheduler.v
add_file $ROOT/rtl/system/sine_rom.v
add_file $ROOT/rtl/system/tone_src.v
add_file $ROOT/rtl/system/i2s_tx.v
add_file $ROOT/rtl/system/i2s_tx_official.v
add_file $ROOT/project/synth_top.v

# ---- 约束 ----
add_file $ROOT/constraint/tang_mega138k.cst
add_file $ROOT/constraint/tang_mega138k.sdc

# ---- GAO 片上逻辑分析仪（调试用：抓 I2S 三线，触发 WS=1）----
add_file $ROOT/gao/i2s_debug.gao

# ---- 顶层 ----
set_option -top_module synth_top

puts "=== SYNTHESIS ==="
run syn

puts "=== PLACE & ROUTE ==="
run pnr

puts "=== DONE ==="
