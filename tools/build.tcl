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
set DEVVER  {B}

cd $ROOT

create_project -name synth_top -dir $ROOT/project -pn $DEVICE -device_version $DEVVER -force

# ---- 源文件 ----
add_file $ROOT/rtl/common/reset_sync.v
add_file $ROOT/rtl/system/clock_gen.v
add_file $ROOT/rtl/system/sample_scheduler.v
add_file $ROOT/project/synth_check_top.v

# ---- 约束 ----
add_file $ROOT/constraint/tang_mega138k.cst
add_file $ROOT/constraint/tang_mega138k.sdc

# ---- 顶层 ----
set_option -top_module synth_check_top

puts "=== SYNTHESIS ==="
run syn

puts "=== PLACE & ROUTE ==="
run pnr

puts "=== DONE ==="
