param([string]$ModelSimBin='E:/altera/13.0/modelsim_ase/win32aloem')
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$library=Join-Path $root 'sim/legato_modelsim'
$checks=Join-Path $root 'sim/legato_checks'
New-Item -ItemType Directory -Force $checks | Out-Null
if(-not(Test-Path -LiteralPath $library)) {
    & "$ModelSimBin/vlib.exe" $library
    if($LASTEXITCODE -ne 0){throw 'vlib failed'}
}
$sources=Get-ChildItem "$root/rtl" -Recurse -Filter *.v |
    Where-Object Name -ne 'clock_gen.v' | Select-Object -ExpandProperty FullName
$tests=@('tb_glide','tb_legato_core','tb_controls_display','tb_merged_dashboard','tb_test_dashboard')
$benches=$tests | ForEach-Object {"$root/sim/audio_core_tb/$_.v"}
Push-Location $checks
try {
    & "$ModelSimBin/vlog.exe" -sv -work $library "+incdir+$root/rtl/common" `
        "+incdir+$root/rtl/input" @sources @benches `
        "$root/sim/clock_gen_stub.v" "$root/project/instrument_24_rgb_top.v" |
        Out-File 'compile.log'
    if($LASTEXITCODE -ne 0){throw 'legato/top compilation failed; see compile.log'}
    foreach($test in $tests) {
        $output=& "$ModelSimBin/vsim.exe" -c -lib $library $test -do 'run -all; quit -f' 2>&1
        $exitCode=$LASTEXITCODE
        $output | Out-File "$test.log"
        $output | Select-String 'PASS|Fatal|Error'
        if($exitCode -ne 0 -or ($output -join "`n") -notmatch 'PASS' -or
           ($output -join "`n") -match '(?i)\*\* (fatal|error)|FATAL:') {
            throw "$test failed; see $checks/$test.log"
        }
    }
    $output=& "$ModelSimBin/vsim.exe" -c -lib $library instrument_24_rgb_top `
        -do 'run 0; quit -f' 2>&1
    $exitCode=$LASTEXITCODE
    $output | Out-File 'merged_top.log'
    if($exitCode -ne 0 -or ($output -join "`n") -match '(?i)\*\* (fatal|error)') {
        throw 'merged top elaboration failed; see merged_top.log'
    }
    Write-Output 'PASS merged top elaboration (PLL stub; no physical timing claim)'
} finally {Pop-Location}
