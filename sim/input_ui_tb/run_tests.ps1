param(
    [string]$VivadoBin = 'E:/vivado2022.2/Vivado/2022.2/bin',
    [string[]]$Tests = @('tb_input','tb_matrix_scan','tb_matrix_scan_min',
        'tb_matrix_keyboard','tb_key_map','tb_keyboard_input','tb_encoder',
        'tb_parameter_manager','tb_parameter_switch','tb_encoder_control','tb_input_top','tb_ui','tb_sensor')
)
$ErrorActionPreference = 'Stop'
$projectDir = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$rtlFiles = @(Get-ChildItem (Join-Path $projectDir 'rtl/input') -Filter '*.v') +
            @(Get-ChildItem (Join-Path $projectDir 'rtl/ui') -Filter '*.v')
$testFiles = @(Get-ChildItem $PSScriptRoot -Filter 'tb_*.v')
$sources = @($rtlFiles + $testFiles | Where-Object Length -gt 0 | ForEach-Object FullName)
$resultDir = Join-Path $PSScriptRoot 'results'
New-Item -ItemType Directory -Force $resultDir | Out-Null
foreach ($test in $Tests) {
    if ($test -notmatch '^tb_[a-z0-9_]+$') { throw "Invalid test name: $test" }
    $workDir = Join-Path $resultDir $test
    New-Item -ItemType Directory -Force $workDir | Out-Null
    Push-Location $workDir
    try {
        & (Join-Path $VivadoBin 'xvlog.bat') -i (Join-Path $projectDir 'rtl/input') @sources *> compile.log
        if ($LASTEXITCODE -ne 0) { throw "$test compile failed: $workDir/compile.log" }
        & (Join-Path $VivadoBin 'xelab.bat') $test -debug typical -s test_snapshot *> elaborate.log
        if ($LASTEXITCODE -ne 0) { throw "$test elaborate failed: $workDir/elaborate.log" }
        $waveScript = (Join-Path $PSScriptRoot 'run_wave.tcl').Replace('\','/')
        & (Join-Path $VivadoBin 'xsim.bat') test_snapshot -tclbatch $waveScript *> simulation.log
        $simExit = $LASTEXITCODE
        $log = Get-Content simulation.log -Raw
        # XSim may return exit code 0 even after a Verilog $fatal.
        if ($simExit -ne 0 -or $log -match '(?im)^\s*(Fatal:|ERROR:|FAIL)' -or $log -notmatch '(?m)^PASS') {
            throw "$test FAILED: $workDir/simulation.log"
        }
        if (!(Test-Path waveform.vcd) -or (Get-Item waveform.vcd).Length -lt 100) {
            throw "$test has no waveform recording"
        }
        Write-Output "PASS $test (simulation.log, waveform.vcd, test_snapshot.wdb)"
    } finally { Pop-Location }
}
Write-Output "All $($Tests.Count) selected tests passed."
