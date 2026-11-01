@echo off
set PYTHONUTF8=1
where pyw >nul 2>nul
if not errorlevel 1 (
    start "" pyw -3 "%~dp0instrument_acceptance.pyw"
    exit /b
)
where pythonw >nul 2>nul
if not errorlevel 1 (
    start "" pythonw "%~dp0instrument_acceptance.pyw"
    exit /b
)
echo Python not found. Install Python 3 with Tcl/Tk and add it to PATH.
pause
