param(
    [ValidateSet('A1', 'A2', 'A3', 'A3Long', 'Guitar', 'Piano', 'GuitarMelody', 'BianzhongAudition', 'All')]
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
if ($Stage -in @('A3', 'All')) { $tests += 'tb_audio_core_a3' }
if ($Stage -eq 'A3Long') {
    $tests += @('tb_audio_core_a3_long', 'tb_audio_core_a3_audition')
}
if ($Stage -eq 'Guitar') { $tests += 'tb_audio_core_guitar' }
if ($Stage -eq 'Piano') { $tests += 'tb_audio_core_piano_melody' }
if ($Stage -eq 'GuitarMelody') { $tests += 'tb_audio_core_guitar_melody' }
if ($Stage -eq 'BianzhongAudition') { $tests += 'tb_audio_core_bianzhong' }
$rtl = Get-ChildItem (Join-Path $repo 'rtl/audio_core') -Filter *.v |
    ForEach-Object FullName
Push-Location $build
try {
    foreach ($test in $tests) {
        $output = Join-Path $build "$test.vvp"
        $defines = @()
        if ($Stage -eq 'Piano') { $defines += '-DPIANO_REFERENCE' }
        if ($test -eq 'tb_audio_core_guitar_melody') { $defines += '-DGUITAR_MELODY' }
        $test_sources = @((Join-Path $PSScriptRoot "$test.v"))
        if ($test -eq 'tb_audio_core_guitar_melody') {
            $test_sources += (Join-Path $PSScriptRoot 'tb_audio_core_piano_melody.v')
        }
        & iverilog -g2005 -s $test -I (Join-Path $repo 'rtl/common') @defines `
            -o $output $rtl $test_sources
        if ($LASTEXITCODE -ne 0) { throw "$test compilation failed" }
        & vvp $output
        if ($LASTEXITCODE -ne 0) { throw "$test simulation failed" }
    }
    if ($Stage -in @('A2', 'All')) {
        & python (Join-Path $PSScriptRoot 'check_a2_waveform.py')
        if ($LASTEXITCODE -ne 0) { throw 'A2 waveform analysis failed' }
    }
    if ($Stage -eq 'A3Long') {
        & python (Join-Path $PSScriptRoot 'check_a3_waveform.py')
        if ($LASTEXITCODE -ne 0) { throw 'A3 waveform analysis failed' }
    }
    if ($Stage -eq 'Guitar') {
        & python (Join-Path $PSScriptRoot 'check_guitar_waveform.py')
        if ($LASTEXITCODE -ne 0) { throw 'Guitar waveform analysis failed' }
    }
    if ($Stage -eq 'Piano') {
        & python (Join-Path $PSScriptRoot 'check_piano_melody.py')
        if ($LASTEXITCODE -ne 0) { throw 'Piano waveform analysis failed' }
    }
    if ($Stage -eq 'GuitarMelody') {
        & python (Join-Path $PSScriptRoot 'check_guitar_melody.py')
        if ($LASTEXITCODE -ne 0) { throw 'Guitar melody waveform analysis failed' }
    }
    if ($Stage -eq 'BianzhongAudition') {
        & python (Join-Path $PSScriptRoot 'check_bianzhong.py')
        if ($LASTEXITCODE -ne 0) { throw 'Bianzhong audition waveform analysis failed' }
    }
} finally {
    Pop-Location
}
