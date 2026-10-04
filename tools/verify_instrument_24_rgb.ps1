param([string[]]$Tests = @('tb_keyboard_24_dual','tb_rgb_lcd_800x480','tb_instrument_24_rgb'))
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ms = 'E:\altera\13.0\modelsim_ase\win32aloem'
$run = Join-Path $root 'sim\instrument_24_rgb_build'
New-Item -ItemType Directory -Force $run | Out-Null
Push-Location $run
try {
    & "$ms\vlib.exe" work | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    $sources = @(Get-ChildItem "$root\rtl\audio_core\*.v" | ForEach-Object FullName)
    $sources += @('rtl/common/reset_sync.v','rtl/system/sample_scheduler.v',
        'rtl/system/system_status.v','rtl/system/i2s_tx_official.v',
        'rtl/input/matrix_scan_8x6.v','rtl/input/keyboard_24_dual.v','rtl/input/keyboard_24_input.v',
        'rtl/input/encoder.v','rtl/input/key_debounce.v','rtl/input/encoder_control.v',
        'rtl/input/encoder_b_input.v','rtl/input/encoder_b_control.v','rtl/input/encoder_param_queue.v',
        'rtl/ui/parameter_manager.v',
        'rtl/ui/rgb_lcd_800x480.v','rtl/ui/lcd_status_bridge.v',
        'sim/system_tb/clock_gen_24_sim.v','project/instrument_24_rgb_top.v') |
        ForEach-Object { Join-Path $root $_ }
    $allowed = @('tb_keyboard_24_dual','tb_rgb_lcd_800x480','tb_instrument_24_rgb')
    $benches = $allowed | ForEach-Object { "$root\sim\system_tb\$_.v" }
    & "$ms\vlog.exe" -quiet -sv -work work "+incdir+$root/rtl/common" "+incdir+$root/rtl/input" @sources @benches
    if ($LASTEXITCODE -ne 0) { throw 'vlog failed' }
    foreach ($test in $Tests) {
        if ($test -notin $allowed) { throw "Unknown test: $test" }
        $result = & "$ms\vsim.exe" -c -do 'run -all; quit -f' "work.$test" 2>&1
        $exitCode = $LASTEXITCODE
        $result | Tee-Object -FilePath "$test.log"
        $log = $result -join "`n"
        if ($exitCode -ne 0 -or $log -match '\*\* Fatal|\*\* Error' -or $log -notmatch 'PASS') {
            throw "$test failed"
        }
    }
} finally { Pop-Location }
