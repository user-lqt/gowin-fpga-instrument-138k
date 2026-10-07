param(
    [string]$IcarusBin = '',
    [switch]$TwoTimbres,
    [switch]$NoJoystick,
    [string[]]$Tests = @('tb_fsr_expression_control','tb_pitch_vibrato',
        'tb_encoder_param_queue','tb_audio_frame_buffer','tb_core_hardware',
        'tb_instrument_fsr_vibrato','tb_keyboard_24_dual','tb_rgb_lcd_800x480')
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$compiler = if ($IcarusBin) { Join-Path $IcarusBin 'iverilog.exe' } else { 'iverilog' }
$runtime = if ($IcarusBin) { Join-Path $IcarusBin 'vvp.exe' } else { 'vvp' }
$vibratoSavedPath = $env:PATH
if ($IcarusBin) { $env:PATH = "$IcarusBin;$vibratoSavedPath" }
$run = Join-Path $root ('sim/fsr_vibrato_build/' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Force -Path $run | Out-Null
$sources = @(Get-ChildItem "$root/rtl/audio_core/*.v" | ForEach-Object FullName)
$sources += @('rtl/common/reset_sync.v','rtl/system/sample_scheduler.v',
    'rtl/system/system_status.v','rtl/system/i2s_tx_official.v','rtl/system/audio_frame_buffer.v',
    'rtl/input/matrix_scan_8x6.v','rtl/input/keyboard_24_dual.v','rtl/input/keyboard_24_input.v',
    'rtl/input/encoder.v','rtl/input/key_debounce.v','rtl/input/encoder_control.v',
    'rtl/input/encoder_b_input.v','rtl/input/encoder_b_control.v','rtl/input/encoder_param_queue.v',
    'rtl/input/mcp3008_spi.v','rtl/input/mcp3008_sampler.v','rtl/input/joystick_control.v',
    'rtl/input/expression_mapper.v','rtl/input/fsr_expression_control.v',
    'rtl/ui/parameter_manager.v','rtl/ui/rgb_lcd_800x480.v','rtl/ui/lcd_status_bridge.v',
    'sim/system_tb/clock_gen_24_sim.v','sim/system_tb/mcp3008_model.v',
    'project/instrument_24_rgb_top.v','project/fsr_adc_probe_top.v') | ForEach-Object { Join-Path $root $_ }
$allowed = @('tb_fsr_expression_control','tb_pitch_vibrato','tb_encoder_param_queue',
    'tb_audio_frame_buffer','tb_core_hardware','tb_instrument_fsr_vibrato',
    'tb_keyboard_24_dual','tb_rgb_lcd_800x480','tb_instrument_24_rgb','tb_mcp3008_spi',
    'tb_fsr_adc_probe')
Push-Location $run
try {
    foreach ($test in $Tests) {
        if ($test -notin $allowed) { throw "Unknown test: $test" }
        $benchDir = if ($test -eq 'tb_core_hardware') { 'sim/audio_core_tb' } else { 'sim/system_tb' }
        $bench = Join-Path $root "$benchDir/$test.v"
        $output = Join-Path $run "$test.vvp"
        $parameters = @()
        if ($test -eq 'tb_core_hardware') {
            $parameters = @('-Ptb_core_hardware.ENABLE_EXPRESSION=1','-Ptb_core_hardware.TEST_VIBRATO=1')
            if ($TwoTimbres) { $parameters += '-Ptb_core_hardware.ENABLE_GUITAR=0' }
        }
        if ($NoJoystick -and $test -eq 'tb_instrument_fsr_vibrato') {
            $parameters += '-Ptb_instrument_fsr_vibrato.ENABLE_JOYSTICK=0'
        }
        & $compiler -g2012 -s $test -I "$root/rtl/common" -I "$root/rtl/input" `
            @parameters -o $output @sources $bench
        if ($LASTEXITCODE -ne 0) { throw "$test compilation failed" }
        & $runtime $output 2>&1 | Tee-Object -FilePath "$test.log"
        $exitCode = $LASTEXITCODE
        $log = Get-Content -LiteralPath "$test.log" -Raw
        if ($exitCode -ne 0 -or $log -match 'FATAL|ERROR' -or $log -notmatch 'PASS') {
            throw "$test failed; see $run/$test.log"
        }
    }
    Write-Output "FSR_VIBRATO_TEST_LOGS=$run"
} finally { Pop-Location; $env:PATH = $vibratoSavedPath }
