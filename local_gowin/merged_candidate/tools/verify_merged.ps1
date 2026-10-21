param([string]$IcarusBin='C:/iverilog/bin',[switch]$SkipAudio)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$build=Join-Path $root 'sim/merged_checks'
New-Item -ItemType Directory -Force $build | Out-Null
$sources=Get-ChildItem "$root/rtl" -Recurse -Filter *.v |
    Where-Object {$_.Name -ne 'clock_gen.v'} | Select-Object -ExpandProperty FullName
$tests=@('tb_display_cdc','tb_control_queue_four','tb_adc_expression_merge','tb_joystick_control','tb_joystick_range','tb_strike_formatter','tb_merged_dashboard','tb_bell_profile','tb_bell_paths','tb_bell_allocation','tb_bell_envelope',
    'tb_pcm5102a_i2s','tb_extensions','tb_ble_song_uart','tb_lesson_guide',
    'tb_keyboard_led_strip','tb_controls_display','tb_audio_visualizer','tb_glide','tb_legato_core',
    'tb_keyboard_24_dual','tb_master_volume','tb_guitar_dynamics','tb_fsr_merge',
    'tb_test_dashboard','tb_polyphony_test','tb_fx_wave','tb_merged_audio')
Push-Location $build
try {
    foreach($test in $tests) {
        if($SkipAudio -and $test -in @('tb_merged_audio','tb_polyphony_test')){continue}
        & "$IcarusBin/iverilog.exe" -g2012 -s $test -I "$root/rtl/common" -I "$root/rtl/input" `
            -o "$test.vvp" @sources "$root/sim/audio_core_tb/$test.v"
        if($LASTEXITCODE -ne 0){throw "$test compile failed"}
        $output=& "$IcarusBin/vvp.exe" "$test.vvp" 2>&1
        $output | Tee-Object "$test.log"
        if($LASTEXITCODE -ne 0 -or ($output -join "`n") -notmatch 'PASS' -or
            ($output -join "`n") -match 'FATAL'){throw "$test failed"}
    }
    & "$IcarusBin/iverilog.exe" -g2012 -s instrument_24_rgb_top `
        -I "$root/rtl/common" -I "$root/rtl/input" -o merged_top.vvp `
        @sources "$root/sim/clock_gen_stub.v" "$root/project/instrument_24_rgb_top.v"
    if($LASTEXITCODE -ne 0){throw 'top-level compile failed'}
    Write-Output 'PASS merged top-level structural compile (PLL blackbox)'
    if($SkipAudio){Write-Output 'Audio smoke skipped here; run tools/check_merged_audio.do separately in ModelSim.'}
} finally {Pop-Location}
