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
    $results = foreach ($shared in 0, 1) {
        $prefix = (Join-Path $build "string_logic_$shared").Replace('\', '/')
        $commands = @(
            'read_verilog rtl/audio_core/plucked_string.v',
            "chparam -set SHARE_ARITHMETIC $shared -set DYNAMIC_PITCH 1 plucked_string",
            'hierarchy -top plucked_string',
            'proc', 'opt', 'memory -nomap', 'opt', 'flatten', 'techmap', 'opt',
            'stat',
            "write_json `"$prefix.json`""
        ) -join '; '
        & $Yosys -q -Q -T -l "$prefix.log" -p $commands | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "String resource mode $shared failed." }
        $netlist = Get-Content -LiteralPath "$prefix.json" -Raw | ConvertFrom-Json
        $cells = @($netlist.modules.plucked_string.cells.PSObject.Properties |
            ForEach-Object { $_.Value })
        $comb = @($cells | Where-Object { $_.type -in @(
            '$_AND_', '$_MUX_', '$_NOT_', '$_OR_', '$_XOR_'
        ) }).Count
        $flops = @($cells | Where-Object { $_.type -like '$_DFF*' }).Count
        $memories = @($cells | Where-Object { $_.type -eq '$mem_v2' })
        if ($memories.Count -ne 1) { throw 'Expected one unchanged delay memory.' }
        $memoryBits = [Convert]::ToInt32($memories[0].parameters.WIDTH, 2) *
            [Convert]::ToInt32($memories[0].parameters.SIZE, 2)
        [pscustomobject]@{
            Shared = $shared
            CombinationalGates = $comb
            FlipFlops = $flops
            DelayBits = $memoryBits
        }
    }
    $results | Format-Table -AutoSize
    if ($results[1].CombinationalGates -ge $results[0].CombinationalGates) {
        throw 'No generic combinational reduction.'
    }
    if ($results[0].DelayBits -ne $results[1].DelayBits) {
        throw 'Delay memory changed.'
    }
    $reduction = 100 * (1 - $results[1].CombinationalGates /
        $results[0].CombinationalGates)
    Write-Output ('Generic combinational reduction: {0:F2}% (not Gowin LUT usage).' -f $reduction)
}
finally {
    Pop-Location
    $env:PYTHONPATH = $savedPythonPath
}
