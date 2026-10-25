param([string]$IcarusBin='C:/iverilog/bin')
$ErrorActionPreference='Stop'
$taskRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$taskBuild=Join-Path $taskRoot 'sim/k230_checks'
New-Item -ItemType Directory -Force $taskBuild | Out-Null
$env:PATH="$IcarusBin;$env:PATH"
$taskSources=Get-ChildItem "$taskRoot/rtl" -Recurse -Filter *.v |
    Where-Object {$_.Name -ne 'clock_gen.v'} | Select-Object -ExpandProperty FullName
Push-Location $taskBuild
try {
    foreach($taskTest in @('tb_k230_control','tb_k230_notes','tb_volume_mapping','tb_master_volume','tb_ble_song_uart')) {
        & "$IcarusBin/iverilog.exe" -g2012 -s $taskTest -I "$taskRoot/rtl/common" -I "$taskRoot/rtl/input" `
            -o "$taskTest.vvp" @taskSources "$taskRoot/sim/audio_core_tb/$taskTest.v"
        if($LASTEXITCODE -ne 0){throw "$taskTest compile failed"}
        $taskOutput=& "$IcarusBin/vvp.exe" "$taskTest.vvp" 2>&1
        $taskOutput | Tee-Object "$taskTest.log"
        if($LASTEXITCODE -ne 0 -or ($taskOutput -join "`n") -notmatch 'PASS' -or
                ($taskOutput -join "`n") -match 'FATAL'){throw "$taskTest failed"}
    }
    & "$IcarusBin/iverilog.exe" -g2012 -s instrument_24_rgb_top `
        -I "$taskRoot/rtl/common" -I "$taskRoot/rtl/input" -o k230_top.vvp `
        @taskSources "$taskRoot/sim/clock_gen_stub.v" "$taskRoot/project/instrument_24_rgb_top.v"
    if($LASTEXITCODE -ne 0){throw 'top-level compile failed'}
    Write-Output 'PASS K230 integrated top structural compile (PLL simulation stub)'
} finally {Pop-Location}
