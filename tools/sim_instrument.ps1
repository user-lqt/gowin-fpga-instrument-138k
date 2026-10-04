# Runs the actual instrument top with a simulation-only PLL replacement.
$ErrorActionPreference = 'Stop'
$root = 'E:\GowinProjects\synth_top'
$ms = 'E:\altera\13.0\modelsim_ase\win32aloem'
$run = Join-Path $root 'sim\run_instrument_top'
New-Item -ItemType Directory -Force $run | Out-Null
Set-Location $run
if (Test-Path work) { Remove-Item -LiteralPath work -Recurse -Force }
& "$ms\vlib.exe" work | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
$ab = @(Get-ChildItem "$root\rtl\audio_core\*.v" | ForEach-Object FullName) +
      @(Get-ChildItem "$root\rtl\input\*.v" | ForEach-Object FullName) +
      @(Get-ChildItem "$root\rtl\ui\*.v" | ForEach-Object FullName)
& "$ms\vlog.exe" -quiet -sv -work work `
    +incdir+E:/GowinProjects/synth_top/rtl/common `
    +incdir+E:/GowinProjects/synth_top/rtl/input `
    @ab `
    "$root\rtl\common\reset_sync.v" `
    "$root\rtl\system\sample_scheduler.v" `
    "$root\rtl\system\i2s_tx_official.v" `
    "$root\rtl\system\system_status.v" `
    "$root\sim\system_tb\clock_gen_sim.v" `
    "$root\project\instrument_top.v" `
    "$root\sim\system_tb\tb_instrument_top.v"
if ($LASTEXITCODE -ne 0) { throw 'vlog failed' }
$result = & "$ms\vsim.exe" -c -do 'run -all; quit -f' work.tb_instrument_top 2>&1
$result | Tee-Object -FilePath 'instrument_top_test.log'
if ($LASTEXITCODE -ne 0 -or ($result -join "`n") -notmatch 'PASS instrument_top') {
    throw 'instrument top simulation failed'
}
