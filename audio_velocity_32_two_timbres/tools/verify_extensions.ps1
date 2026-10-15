param([string]$IcarusBin='')
$ErrorActionPreference='Stop'
$featureRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if(!$IcarusBin){$IcarusBin=Join-Path $featureRoot '../tmp/iverilog/bin'}
$featureRun=Join-Path $featureRoot 'sim/audio_core_tb/build/extensions'
New-Item -ItemType Directory -Force $featureRun | Out-Null
$featureSources=@('rtl/input/instrument_link.v','rtl/input/performance_event_merge.v','rtl/input/ble_uart_rx.v',
 'rtl/input/encoder.v','rtl/input/key_debounce.v','rtl/input/encoder_b_control.v',
 'rtl/system/lesson_guide.v','rtl/system/keyboard_led_strip.v','rtl/ui/audio_visualizer.v','rtl/ui/instrument_dashboard.v') |
 ForEach-Object {Join-Path $featureRoot $_}
Push-Location $featureRun
try {
 foreach($featureTest in @('tb_extensions','tb_ble_song_uart','tb_lesson_guide','tb_keyboard_led_strip','tb_controls_display','tb_audio_visualizer')){
  & "$IcarusBin/iverilog.exe" -g2012 -I "$featureRoot/rtl/common" -s $featureTest -o "$featureTest.vvp" @featureSources "$featureRoot/sim/audio_core_tb/$featureTest.v"
  if($LASTEXITCODE -ne 0){throw "$featureTest compile failed"}
  $featureOutput=& "$IcarusBin/vvp.exe" "$featureTest.vvp" 2>&1
  $featureOutput | Tee-Object "$featureTest.log"
  if($LASTEXITCODE -ne 0 -or ($featureOutput -join "`n") -notmatch 'PASS' -or ($featureOutput -join "`n") -match 'FATAL'){
   throw "$featureTest simulation failed"
  }
 }
} finally {Pop-Location}
