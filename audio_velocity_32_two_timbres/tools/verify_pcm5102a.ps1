param([string]$IcarusBin='')
$ErrorActionPreference='Stop'
$pcmRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if(!$IcarusBin){$IcarusBin=Join-Path $pcmRoot '../tmp/iverilog/bin'}
$pcmBuild=Join-Path $pcmRoot 'sim/audio_core_tb/build/pcm5102a'
New-Item -ItemType Directory -Force $pcmBuild | Out-Null
Push-Location $pcmBuild
try {
 & "$IcarusBin/iverilog.exe" -g2012 -s tb_pcm5102a_i2s -o pcm5102a.vvp "$pcmRoot/rtl/system/sample_scheduler.v" "$pcmRoot/rtl/system/i2s_tx_pcm5102a.v" "$pcmRoot/sim/audio_core_tb/tb_pcm5102a_i2s.v"
 if($LASTEXITCODE -ne 0){throw 'I2S compile failed'}
 $pcmResult=& "$IcarusBin/vvp.exe" pcm5102a.vvp 2>&1
 $pcmResult | Tee-Object pcm5102a.log
 if($LASTEXITCODE -ne 0 -or ($pcmResult -join "`n") -notmatch 'PASS'){throw 'I2S simulation failed'}
} finally {Pop-Location}
