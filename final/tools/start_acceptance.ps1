$ErrorActionPreference = 'Stop'
$pythonArgs = @()
if ($env:PYTHON) {
    $python = $env:PYTHON
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $python = 'python'
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    $python = 'py'
    $pythonArgs = @('-3')
} else {
    throw 'Python 3 not found. Install Python with Tk or set the PYTHON environment variable.'
}
& $python @pythonArgs -c "import numpy, matplotlib, tkinter"
if ($LASTEXITCODE -ne 0) {
    throw 'Python dependencies missing. Install Python 3 with Tk, then run: python -m pip install numpy matplotlib'
}
& $python @pythonArgs (Join-Path $PSScriptRoot 'acceptance_gui.py')
if ($LASTEXITCODE -ne 0) { throw 'Acceptance tool failed' }
