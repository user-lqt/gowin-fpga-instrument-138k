param(
    [ValidateSet('A1', 'A2', 'All')]
    [string]$Stage = 'A2'
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$build = Join-Path $PSScriptRoot 'build/iverilog'
New-Item -ItemType Directory -Force -Path $build | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $build 'waveforms') | Out-Null
$tests = @()
if ($Stage -in @('A1', 'All')) { $tests += 'tb_audio_core' }
if ($Stage -in @('A2', 'All')) {
    $tests += @('tb_adsr', 'tb_mixer', 'tb_voice_allocator', 'tb_voice', 'tb_audio_core_a2')
}
$rtl = Get-ChildItem (Join-Path $repo 'rtl/audio_core') -Filter *.v |
    ForEach-Object FullName
Push-Location $build
try {
    foreach ($test in $tests) {
        $output = Join-Path $build "$test.vvp"
        & iverilog -g2005 -s $test -I (Join-Path $repo 'rtl/common') `
            -o $output $rtl (Join-Path $PSScriptRoot "$test.v")
        if ($LASTEXITCODE -ne 0) { throw "$test compilation failed" }
        & vvp $output
        if ($LASTEXITCODE -ne 0) { throw "$test simulation failed" }
    }
    if ($Stage -in @('A2', 'All')) {
        & python (Join-Path $PSScriptRoot 'check_a2_waveform.py')
        if ($LASTEXITCODE -ne 0) { throw 'A2 waveform analysis failed' }
    }
} finally {
    Pop-Location
}
