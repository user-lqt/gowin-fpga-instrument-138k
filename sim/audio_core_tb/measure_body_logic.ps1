param(
    [string]$Yosys = 'yosys'
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$build = Join-Path $PSScriptRoot 'build/iverilog'
$bundledTools = Join-Path $PSScriptRoot 'build/resource_tools'
New-Item -ItemType Directory -Force -Path $build | Out-Null
$savedPythonPath = $env:PYTHONPATH
if ($Yosys -eq 'yosys' -and !(Get-Command $Yosys -ErrorAction SilentlyContinue)) {
    $Yosys = Join-Path $bundledTools 'bin/yowasp-yosys.exe'
    if (!(Test-Path -LiteralPath $Yosys)) {
        throw 'Install Yosys or pass -Yosys with its executable path.'
    }
    $env:PYTHONPATH = $bundledTools
}
Push-Location $repo
try {
    $results = foreach ($top in 'guitar_body_tone_bank', 'guitar_body_ram_bank') {
        $prefix = (Join-Path $build $top).Replace('\', '/')
        $commands = @(
            "read_verilog rtl/audio_core/$top.v",
            "chparam -set LANES 16 $top",
            "hierarchy -top $top",
            'proc', 'opt', 'memory -nomap', 'opt', 'flatten', 'techmap', 'opt',
            'stat',
            "write_json `"$prefix.json`""
        ) -join '; '
        & $Yosys -q -Q -T -l "$prefix.log" -p $commands | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "$top resource measurement failed." }
        $netlist = Get-Content -LiteralPath "$prefix.json" -Raw | ConvertFrom-Json
        $cells = @($netlist.modules.$top.cells.PSObject.Properties |
            ForEach-Object { $_.Value })
        $comb = @($cells | Where-Object { $_.type -in @(
            '$_AND_', '$_MUX_', '$_NOT_', '$_OR_', '$_XOR_'
        ) }).Count
        $flops = @($cells | Where-Object { $_.type -like '$_DFF*' }).Count
        $memories = @($cells | Where-Object { $_.type -eq '$mem_v2' })
        $memoryBits = 0
        foreach ($memory in $memories) {
            $memoryBits += [Convert]::ToInt32($memory.parameters.WIDTH, 2) *
                [Convert]::ToInt32($memory.parameters.SIZE, 2)
        }
        [pscustomobject]@{
            Module = $top
            Lanes = 16
            CombinationalGates = $comb
            FlipFlops = $flops
            StateRamBits = $memoryBits
        }
    }
    $results | Export-Csv (Join-Path $build 'body_logic.csv') -NoTypeInformation
    $results | Format-Table -AutoSize
    if ($results[1].CombinationalGates -ge $results[0].CombinationalGates) {
        throw 'No generic combinational reduction.'
    }
    if ($results[1].StateRamBits -ne 16 * 192) {
        throw 'Expected unchanged 16-lane filter histories in RAM.'
    }
    Write-Output ('Generic combinational reduction: {0:F2}% (not Gowin LUT usage).' -f
        (100 * (1 - $results[1].CombinationalGates / $results[0].CombinationalGates)))
}
finally {
    Pop-Location
    $env:PYTHONPATH = $savedPythonPath
}
