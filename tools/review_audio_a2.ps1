param([string]$AudioRoot = 'E:\GowinProjects\synth_top_a2_review_359f090')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ms = 'E:\altera\13.0\modelsim_ase\win32aloem'
$run = Join-Path $AudioRoot 'sim\audio_core_tb\build\iverilog'
New-Item -ItemType Directory -Force (Join-Path $run 'waveforms') | Out-Null
Set-Location $run
& "$ms\vlib.exe" work | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
$audio = @(Get-ChildItem "$AudioRoot\rtl\audio_core\*.v" | ForEach-Object FullName)
$tests = @('tb_adsr','tb_mixer','tb_voice_allocator','tb_voice','tb_audio_core_a2','tb_audio_core')
$benches = @($tests | ForEach-Object { "$AudioRoot\sim\audio_core_tb\$_.v" })
& "$ms\vlog.exe" -quiet -sv -work work "+incdir+$($AudioRoot.Replace('\','/'))/rtl/common" @audio @benches
if ($LASTEXITCODE -ne 0) { throw 'audio vlog failed' }
foreach ($test in $tests) {
    $result = & "$ms\vsim.exe" -c -do 'run -all; quit -f' "work.$test" 2>&1
    $exitCode = $LASTEXITCODE
    $result | Tee-Object -FilePath "$test.log"
    $log = $result -join "`n"
    if ($exitCode -ne 0 -or $log -match '\[FAIL\]|\*\* Fatal|\*\* Error' -or $log -notmatch 'PASS') {
        throw "$test failed"
    }
}
$inputUi = @(Get-ChildItem "$root\rtl\input\*.v" | ForEach-Object FullName) +
           @(Get-ChildItem "$root\rtl\ui\*.v" | ForEach-Object FullName)
& "$ms\vlog.exe" -quiet -sv -work work `
    "+incdir+$($root.Replace('\','/'))/rtl/common" `
    "+incdir+$($root.Replace('\','/'))/rtl/input" @inputUi `
    "$root\rtl\common\reset_sync.v" "$root\rtl\system\sample_scheduler.v" `
    "$root\rtl\system\i2s_tx_official.v" "$root\rtl\system\system_status.v" `
    "$root\sim\system_tb\clock_gen_sim.v" "$root\project\instrument_top.v" `
    "$root\sim\system_tb\tb_a2_board_review.v"
if ($LASTEXITCODE -ne 0) { throw 'board vlog failed' }
$result = & "$ms\vsim.exe" -c -do 'run -all; quit -f' work.tb_a2_board_review 2>&1
$result | Tee-Object -FilePath 'board_review.log'
$log = $result -join "`n"
if ($LASTEXITCODE -ne 0 -or $log -match '\*\* Fatal|\*\* Error' -or $log -notmatch 'PASS board review') {
    throw 'board review harness failed'
}
& "$ms\vlog.exe" -quiet -sv -work work "$root\sim\system_tb\tb_a2_retrigger_review.v"
if ($LASTEXITCODE -ne 0) { throw 'retrigger vlog failed' }
$result = & "$ms\vsim.exe" -c -do 'run -all; quit -f' work.tb_a2_retrigger_review 2>&1
$result | Tee-Object -FilePath 'retrigger_review.log'
$log = $result -join "`n"
if ($LASTEXITCODE -ne 0 -or $log -match '\*\* Fatal|\*\* Error' -or $log -notmatch 'PASS retrigger review') {
    throw 'retrigger review reproduction failed'
}
