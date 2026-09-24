# ============================================================================
# sim.ps1 —— 用 ModelSim 跑 testbench（免 GUI）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\sim.ps1 tb_scheduler
#   powershell -ExecutionPolicy Bypass -File tools\sim.ps1 tb_scheduler gui
#
# 说明：Gowin 的 gw_sh 只支持 syn / pnr，不含仿真器；本机可用的仿真器是
#       Altera 自带的 ModelSim ASE。
# ============================================================================
param(
    [string]$Tb = "tb_scheduler",
    [string]$Mode = "batch"
)

$ErrorActionPreference = "Stop"

$MS   = "E:\altera\13.0\modelsim_ase\win32aloem"
$ROOT = "E:\GowinProjects\synth_top"
$SIM  = Join-Path $ROOT "sim\delta"

if (-not (Test-Path $MS)) {
    Write-Host "ModelSim not found at $MS" -ForegroundColor Red
    Write-Host "请修改本脚本里的 `$MS 指向你机器上的 vsim.exe 目录" -ForegroundColor Yellow
    exit 1
}

New-Item -ItemType Directory -Force -Path $SIM | Out-Null
Set-Location $SIM

# 清掉上一次的结果
if (Test-Path work) { Remove-Item work -Recurse -Force }
& "$MS\vlib.exe" work | Out-Null

# 编译：RTL + testbench
$rtl = @(
    "$ROOT\rtl\common\reset_sync.v",
    "$ROOT\rtl\system\clock_gen.v",
    "$ROOT\rtl\system\sample_scheduler.v"
)
$tbFile = "$ROOT\tb\$Tb.v"

if (-not (Test-Path $tbFile)) {
    Write-Host "testbench not found: $tbFile" -ForegroundColor Red
    exit 1
}

# clock_gen 里含厂商原语，仿真时排除（由各 tb 自己用行为模型替代）
$srcs = @()
foreach ($f in $rtl) { if ((Test-Path $f) -and ($f -notmatch "clock_gen")) { $srcs += $f } }
$srcs += $tbFile

Write-Host "compiling: $($srcs -join ', ')"
& "$MS\vlog.exe" -quiet -work work @srcs

if ($Mode -eq "gui") {
    & "$MS\vsim.exe" -do "add wave -r /*; run -all" work.$Tb
} else {
    & "$MS\vsim.exe" -c -do "run -all; quit -f" work.$Tb
}
