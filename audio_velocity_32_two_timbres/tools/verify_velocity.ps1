$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$bin='E:/vivado2022.2/Vivado/2022.2/bin'
$run=Join-Path $root 'sim/audio_core_tb/build/xsim'
New-Item -ItemType Directory -Force "$run/waveforms" | Out-Null
Push-Location $run
try {
    $rtl=@(Get-ChildItem "$root/rtl/audio_core/*.v" | ForEach-Object FullName)
    $tests=@('tb_velocity_response','tb_velocity_cadence','tb_keyboard_24_dual','tb_volume_mapping','tb_controls_display','tb_glide','tb_fx_wave','tb_polyphony_test','tb_fsr_merge','tb_keyboard_led_strip','tb_lesson_guide')
    $sources=$rtl+@("$root/rtl/input/keyboard_24_dual.v","$root/rtl/ui/parameter_manager.v","$root/sim/audio_core_tb/plucked_string_reference.v")
    $sources+=@($tests | ForEach-Object {"$root/sim/audio_core_tb/$_.v"})
    $sources+=@('encoder','key_debounce','encoder_b_control' | ForEach-Object {"$root/rtl/input/$_.v"})
    $sources+=@('mcp3008_spi','mcp3008_sampler','expression_mapper','fsr_expression_control','encoder_param_queue' | ForEach-Object {"$root/rtl/input/$_.v"})
    $sources+=@("$root/rtl/system/audio_delay_fx.v","$root/rtl/system/polyphony_test.v","$root/rtl/ui/waveform_buffer.v")
    $sources+=@("$root/rtl/system/keyboard_led_strip.v","$root/rtl/system/lesson_guide.v")
    & "$bin/xvlog.bat" --sv -i "$root/rtl/common" -i "$root/rtl/input" @sources
    if($LASTEXITCODE -ne 0){throw 'compile failed'}
    foreach($test in $tests){
        & "$bin/xelab.bat" $test -s $test --timescale 1ns/1ps
        if($LASTEXITCODE -ne 0){throw 'elaboration failed'}
        $output=& "$bin/xsim.bat" $test -runall 2>&1
        $output | Tee-Object "$test.log"
        if($LASTEXITCODE -ne 0 -or ($output -join "`n") -notmatch 'PASS' -or ($output -join "`n") -match 'Fatal:'){throw "$test failed"}
    }
} finally {Pop-Location}
