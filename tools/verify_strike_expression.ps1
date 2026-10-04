$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$bin='E:\vivado2022.2\Vivado\2022.2\bin'
$run=Join-Path $root 'sim/strike_expression_build'
New-Item -ItemType Directory -Force $run | Out-Null
Push-Location $run
try {
    $sources=@(Get-ChildItem "$root/rtl/audio_core/*.v" | ForEach-Object FullName)
    $sources += "$root/rtl/input/keyboard_24_dual.v"
    $sources += "$root/sim/system_tb/tb_keyboard_24_dual.v"
    $sources += "$root/sim/system_tb/tb_strike_expression.v"
    $sources += @('rtl/common/reset_sync.v','rtl/system/sample_scheduler.v',
      'rtl/system/system_status.v','rtl/system/i2s_tx_official.v',
      'rtl/input/matrix_scan_8x6.v','rtl/input/keyboard_24_input.v',
      'rtl/input/encoder.v','rtl/input/key_debounce.v','rtl/input/encoder_control.v',
      'rtl/input/encoder_b_input.v','rtl/input/encoder_b_control.v','rtl/input/encoder_param_queue.v',
      'rtl/input/mcp3008_spi.v','rtl/input/mcp3008_sampler.v','rtl/input/joystick_control.v',
      'rtl/ui/parameter_manager.v',
      'rtl/ui/rgb_lcd_800x480.v','rtl/ui/lcd_status_bridge.v',
      'sim/system_tb/clock_gen_24_sim.v','project/instrument_24_rgb_top.v',
      'sim/system_tb/tb_instrument_24_rgb.v','sim/system_tb/tb_ec11_diagnostic.v',
      'sim/system_tb/tb_ec11_formal.v','sim/system_tb/tb_dual_ec11.v',
      'sim/system_tb/tb_encoder_param_queue.v','sim/system_tb/tb_rgb_lcd_800x480.v',
      'sim/system_tb/tb_mcp3008_spi.v','sim/system_tb/tb_joystick_control.v') | ForEach-Object {Join-Path $root $_}
    & "$bin/xvlog.bat" --sv -i "$root/rtl/common" -i "$root/rtl/input" @sources
    if($LASTEXITCODE -ne 0){throw 'compile failed'}
    foreach($test in @('tb_mcp3008_spi','tb_joystick_control','tb_rgb_lcd_800x480','tb_encoder_param_queue','tb_dual_ec11','tb_ec11_formal','tb_ec11_diagnostic','tb_keyboard_24_dual','tb_strike_expression','tb_instrument_24_rgb')) {
        & "$bin/xelab.bat" $test -s $test --timescale 1ns/1ps
        if($LASTEXITCODE -ne 0){throw 'elaboration failed'}
        $output=& "$bin/xsim.bat" $test -runall 2>&1
        $output | Tee-Object "$test.log"
        if($LASTEXITCODE -ne 0 -or ($output -join "`n") -notmatch 'PASS' -or ($output -join "`n") -match 'Fatal:'){throw 'simulation failed'}
    }
} finally {Pop-Location}
