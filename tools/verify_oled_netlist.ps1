param([switch]$InitOnly)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ms='E:\altera\13.0\modelsim_ase\win32aloem'
$run=Join-Path $root $(if($InitOnly){'sim\oled_init_netlist_build'}else{'sim\oled_netlist_build'})
New-Item -ItemType Directory -Force $run | Out-Null
Push-Location $run
try {
    & "$ms\vlib.exe" work | Out-Null
    & "$ms\vlog.exe" -quiet -work work 'E:/Gowin/Gowin_V1.9.12_x64/IDE/simlib/gw5a/prim_sim.v'
    if($LASTEXITCODE -ne 0){throw 'primitive compile failed'}
    & "$ms\vlog.exe" -quiet -sv -work work "$root/project/oled_panel_probe_top/impl/gwsynthesis/oled_panel_probe_top.vg" "$root/sim/system_tb/tb_oled_netlist.v"
    if($LASTEXITCODE -ne 0){throw 'netlist compile failed'}
    $extra=@()
    if($InitOnly){$extra=@('-gINIT_ONLY=1')}
    $result=& "$ms\vsim.exe" -c @extra -do 'run -all; quit -f' work.tb_oled_netlist 2>&1
    $code=$LASTEXITCODE
    $result | Tee-Object -FilePath 'tb_oled_netlist.log'
    if($code -ne 0 -or ($result -join "`n") -match '\*\* Fatal|\*\* Error' -or ($result -join "`n") -notmatch 'PASS synthesized'){throw 'netlist test failed'}
} finally {Pop-Location}
