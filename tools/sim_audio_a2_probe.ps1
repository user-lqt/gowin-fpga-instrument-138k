$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ms = 'E:\altera\13.0\modelsim_ase\win32aloem'
$run = Join-Path $root 'sim\run_audio_a2_probe'
New-Item -ItemType Directory -Force $run | Out-Null
Set-Location $run
& "$ms\vlib.exe" work | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
$sources = @(Get-ChildItem "$root\rtl\audio_core\*.v" | ForEach-Object FullName)
& "$ms\vlog.exe" -quiet -sv -work work `
    "+incdir+$($root.Replace('\','/'))/rtl/common" `
    @sources `
    "$root\rtl\common\reset_sync.v" `
    "$root\rtl\system\sample_scheduler.v" `
    "$root\rtl\system\i2s_tx_official.v" `
    "$root\sim\system_tb\clock_gen_sim.v" `
    "$root\project\audio_a2_probe_top.v" `
    "$root\sim\system_tb\tb_audio_a2_probe_top.v"
if ($LASTEXITCODE -ne 0) { throw 'vlog failed' }
$result = & "$ms\vsim.exe" -c -do 'run -all; quit -f' work.tb_audio_a2_probe_top 2>&1
$result | Tee-Object -FilePath 'probe_test.log'
if ($LASTEXITCODE -ne 0 -or ($result -join "`n") -notmatch 'PASS A2 probe') {
    throw 'A2 probe simulation failed'
}
