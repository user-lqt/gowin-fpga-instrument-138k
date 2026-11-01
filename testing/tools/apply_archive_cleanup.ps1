param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$planFile = Join-Path $root 'config\history\folder_cleanup_plan.json'
$plan = Get-Content -LiteralPath $planFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ($plan.root -ne $root) {
    throw 'Application moved after planning; review the plan before applying it.'
}
if (!$Apply) {
    Write-Host "Preview only. Redundant files: $($plan.delete_files.Count)"
    Write-Host 'No files changed. Retained source files are protected by a hash manifest.'
    exit 0
}
if (Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq 'pythonw.exe' -and $_.CommandLine -like '*instrument_acceptance*'
}) {
    throw 'Close the measurement application before applying this plan.'
}

$baseline = Get-Content -LiteralPath (Join-Path $root 'config\retained_source_hashes.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$protected = @{}
foreach ($entry in $baseline.sha256.PSObject.Properties) {
    $protected[[IO.Path]::GetFullPath((Join-Path $root $entry.Name))] = $true
}
$targets = @()
foreach ($relative in $plan.delete_files) {
    if (!(Test-Path -LiteralPath (Join-Path $root $relative))) { continue }
    $path = (Resolve-Path -LiteralPath (Join-Path $root $relative)).Path
    if (!$path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or
        (Get-Item -LiteralPath $path).PSIsContainer -or $protected.ContainsKey($path)) {
        throw "Unsafe deletion target: $path"
    }
    $expected = $plan.delete_sha256.PSObject.Properties[$relative].Value
    if (!$expected -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expected) {
        throw "Redundant file changed after planning: $path"
    }
    $targets += $path
}
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONDONTWRITEBYTECODE = '1'
Push-Location $root
try {
    py -3 tools\audit_measurement_archive.py
    if ($LASTEXITCODE -ne 0) {
        throw 'Source audit failed before cleanup; nothing deleted.'
    }
    foreach ($target in $targets) {
        Remove-Item -LiteralPath $target -Force
    }
    # Remove empty obsolete folders bottom-up, never raw capture directories.
    $directories = @(
        Get-ChildItem -LiteralPath (Join-Path $root 'measurements\reports\evidence') -Directory -Recurse
        Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Directory -Recurse |
            Where-Object { $_.Name -eq '__pycache__' }
        Get-Item -LiteralPath (Join-Path $root 'measurements\renumber_staging_001') -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath (Join-Path $root 'measurements\reports\latency') -Directory -Recurse |
            Where-Object { $_.Name -eq 'evidence' }
    ) | Sort-Object { $_.FullName.Length } -Descending
    foreach ($directory in $directories) {
        $path = $directory.FullName
        if (!$path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe empty-directory target: $path"
        }
        if (!(Get-ChildItem -LiteralPath $path -Force | Select-Object -First 1)) {
            Remove-Item -LiteralPath $path
        }
    }
    py -3 tools\audit_measurement_archive.py
    if ($LASTEXITCODE -ne 0) {
        throw 'Post-cleanup audit failed; preserve the error output.'
    }
    [pscustomobject]@{
        status = 'complete'
        removed_files = $targets.Count
        source_and_link_audit_passed = $true
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'config\history\folder_cleanup_result.json') -Encoding UTF8
} finally {
    Pop-Location
}
Write-Host "Removed $($targets.Count) redundant files. Retained sources and links verified."
