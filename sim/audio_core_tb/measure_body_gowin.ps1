param(
    [string]$Gowin = 'D:\gowin eda\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe'
)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $Gowin)) {
    throw 'Pass -Gowin with the local gw_sh.exe path.'
}
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$build = Join-Path $PSScriptRoot 'build/gowin_body'
$script = Join-Path $PSScriptRoot 'profile_body.tcl'
New-Item -ItemType Directory -Force -Path $build | Out-Null
$sources = @($script,
    (Join-Path $repo 'rtl/audio_core/guitar_body_tone_bank.v'),
    (Join-Path $repo 'rtl/audio_core/guitar_body_ram_bank.v'))
$sourceHashes = foreach ($source in $sources) {
    Get-FileHash -LiteralPath $source -Algorithm SHA256
}
$sourceHashes |
    Select-Object Path, Hash |
    Export-Csv (Join-Path $build 'sources.csv') -NoTypeInformation
& $Gowin $script 2>&1 | Tee-Object (Join-Path $build 'synthesis.log')
if ($LASTEXITCODE -ne 0) { throw 'Gowin body measurement failed.' }
$results = foreach ($top in 'guitar_body_tone_bank', 'guitar_body_ram_bank') {
    $directory = Join-Path $build "$top/impl/gwsynthesis"
    $log = Join-Path $directory "$top.log"
    if (!(Test-Path -LiteralPath $log) -or
        (Select-String -LiteralPath $log -Pattern 'ERROR' -Quiet) -or
        !(Select-String -LiteralPath $log -SimpleMatch -Pattern 'GowinSynthesis finish' -Quiet)) {
        throw "$top synthesis did not complete."
    }
    $report = Join-Path $directory "${top}_syn_rsc.xml"
    [xml]$resources = Get-Content -LiteralPath $report -Raw
    $module = $resources.Module
    [pscustomobject]@{
        Module = $top
        Lanes = 16
        LUT = [int]$module.Lut
        ALU = [int]$module.Alu
        Registers = [int]$module.Register
        BSRAM = [int]$module.Bsram
        MULTALU27X18 = [int]$module.MULTALU27X18
    }
}
$results | Export-Csv (Join-Path $build 'resources.csv') -NoTypeInformation
$results | Format-Table -AutoSize
if ($results[1].LUT -ge $results[0].LUT) {
    throw 'No measured Gowin LUT reduction.'
}
Write-Output 'GOWIN BODY MEASUREMENT PASS: standalone 16-lane modules, not system route acceptance.'
