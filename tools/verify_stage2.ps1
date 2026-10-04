param([string[]]$Tests = @())
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ms = 'E:\altera\13.0\modelsim_ase\win32aloem'
$run = Join-Path $root 'sim\audio_core_tb\build\iverilog'
New-Item -ItemType Directory -Force (Join-Path $run 'waveforms') | Out-Null
Push-Location $run
try {
    & "$ms\vlib.exe" work | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    $audio = @(Get-ChildItem "$root\rtl\audio_core\*.v" | ForEach-Object FullName)
    $inputUi = @(Get-ChildItem "$root\rtl\input\*.v" | ForEach-Object FullName) +
               @(Get-ChildItem "$root\rtl\ui\*.v" | ForEach-Object FullName)
    $audioTests = @('tb_adsr','tb_mixer','tb_voice_allocator','tb_voice','tb_audio_core_a2','tb_audio_core','tb_timbres')
    $systemTests = @('tb_pt8211_tx','tb_a2_retrigger_review','tb_a2_board_review',
                     'tb_instrument_top','tb_audio_overflow_status','tb_stage2_controls',
                     'tb_oled_display','tb_oled_address_3d','tb_oled_all_on','tb_oled_i2c_timing',
                     'tb_instrument_oled_top','tb_oled_vendor_probe')
    $benches = @($audioTests | ForEach-Object { "$root\sim\audio_core_tb\$_.v" }) +
               @($systemTests | ForEach-Object { "$root\sim\system_tb\$_.v" })
    & "$ms\vlog.exe" -quiet -sv -work work `
        "+incdir+$($root.Replace('\','/'))/rtl/common" `
        "+incdir+$($root.Replace('\','/'))/rtl/input" @audio @inputUi `
        "$root\rtl\common\reset_sync.v" "$root\rtl\system\sample_scheduler.v" `
        "$root\rtl\system\i2s_tx_official.v" "$root\rtl\system\system_status.v" `
        "$root\sim\system_tb\clock_gen_sim.v" "$root\project\instrument_top.v" @benches
    if ($LASTEXITCODE -ne 0) { throw 'vlog failed' }
    $selectedTests = $audioTests + $systemTests
    if ($Tests.Count -gt 0) {
        foreach ($test in $Tests) {
            if ($test -notin $selectedTests) { throw "Unknown test: $test" }
        }
        $selectedTests = $Tests
    }
    foreach ($test in $selectedTests) {
        $result = & "$ms\vsim.exe" -c -do 'run -all; quit -f' "work.$test" 2>&1
        $exitCode = $LASTEXITCODE
        $result | Tee-Object -FilePath "$test.log"
        $log = $result -join "`n"
        if ($exitCode -ne 0 -or $log -match '\[FAIL\]|\*\* Fatal|\*\* Error' -or $log -notmatch 'PASS') {
            throw "$test failed"
        }
    }
    if ('tb_audio_core_a2' -in $selectedTests) {
        & python "$root\sim\audio_core_tb\check_a2_waveform.py"
        if ($LASTEXITCODE -ne 0) { throw 'waveform analysis failed' }
    }
} finally {
    Pop-Location
}
