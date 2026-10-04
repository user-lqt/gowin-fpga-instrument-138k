# C 联调仿真记录（2026-09-25）

## 使用的代码版本

- C：主工作区 `main` 1b47f25，加上本地待提交的协议、`system_status.v` 和联调测试。
- A：`dev-audio` afc7a89，单音核心，已提供 v2 溢出输出；此提交仅修复测试台声明顺序，RTL 与 5158e5b 相同。
- B：`dev-input` 2c45f82，`input_top`、键盘扫描与参数管理。

先前联调测试引用 A/B 分支快照；2026-09-25 已将相同版本的 A/B RTL 导入主工作区，新增独立 `instrument_top`。A、B 当前均使用与 C 相同的 `clk_audio`；测试台生成 12.288 MHz 及真实 `/256` 的 `sample_tick`。

`tb_instrument_top.v` 直接例化实际乐器顶层，用 `clock_gen_sim.v` 代替厂商 PLL，验证按键、A 的音频样本、I2S 串行数据、松键静音与行线三态。运行 `powershell -ExecutionPolicy Bypass -File tools/sim_instrument.ps1`，结果为 `PASS instrument_top note on/off through real B and A, nonzero=191`。乐器工程布局布线完成，接线与首次上板说明见 `docs/C_INSTRUMENT_BRINGUP.md`。

2026-09-26 A2 更新：A 的四声部和独立 ADSR 已接入。`tb_instrument_top` 现增加四键和弦、松开一键其余音保留、全键松开后释放结束；`tb_keyboard_audio_chain` 的 16 键突发仍全部到达，队列峰值随扫描与采样相位为 15/16，且无溢出。A2 独立数值与频谱检查见 `sim/audio_core_tb/A2_README.md`。新固件必须重新下载，当前板上先前观察到的单音现象不能作为四复音实测证据。

## 已验证

`tb_keyboard_audio_chain.v`：

1. `system_ready` 后 B 完成启动，连续两个默认参数送入 A，A 的音量变成 33026。
2. 矩阵键盘按下 C4（note 60）后，A 输出持续非零采样，C 的 16 bit 槽 I2S 时钟持续运行。
3. 松键产生 NOTE_OFF，音频回到数值 0，无重复事件。
4. 16 键同时变化时，B 输出 16 个 NOTE_ON；A 队列最高达到 16/16，全部到达、队列排空且未溢出。
5. 16 键同时松开时，B 输出 16 个 NOTE_OFF；全部消费且最终静音。

ModelSim 结果：`PASS real B keyboard -> A audio -> C I2S: params=2 notes=17/17 max_queue=16 nonzero_samples=516 ws_edges=1651`。日志在 `keyboard_audio_chain.log`。

`tb_audio_overflow_status.v` 使用 A 新提交的真实状态口，验证事件溢出后的静音、C 关闭 B、复位恢复，以及参数溢出告警后继续运行，结果 PASS。

`tb_system_status.v` 与 `tb_startup_with_input.v` 分别验证 C 状态规则、真实 B 启动顺序和事件故障关闭 B。

A 自带 `tb_audio_core.v` 原先在 ModelSim 10.1d 下因 `tick_cnt` 声明顺序无法编译；`afc7a89` 已修复并推送到 `dev-audio`，原版回归为 46/46 PASS。

## 复跑命令

在 `E:\GowinProjects\synth_top` PowerShell 工作目录中，先用 `vlib work` 创建 ModelSim 库。下列命令中的 `$audioRoot`、`$inputRoot` 是两人分支的本地检出路径：

```powershell
$audioRoot = 'E:\GowinProjects\synth_top_review_audio_5158e5b'
$inputRoot = 'E:\GowinProjects\synth_top_review_input'
$aSrc = @(Get-ChildItem "$audioRoot\rtl\audio_core\*.v" | ForEach-Object FullName)
$bSrc = @(Get-ChildItem "$inputRoot\rtl\input\*.v" | ForEach-Object FullName) + @(Get-ChildItem "$inputRoot\rtl\ui\*.v" | ForEach-Object FullName)
& 'E:\altera\13.0\modelsim_ase\win32aloem\vlog.exe' -quiet -sv -work work +incdir+rtl/common +incdir+$inputRoot/rtl/input +incdir+$audioRoot/rtl/common @bSrc @aSrc rtl/system/sample_scheduler.v rtl/system/i2s_tx_official.v rtl/system/system_status.v sim/system_tb/tb_keyboard_audio_chain.v
& 'E:\altera\13.0\modelsim_ase\win32aloem\vsim.exe' -c -do 'run -all; quit -f' work.tb_keyboard_audio_chain
```

运行时必须检查日志是否含 `PASS`、`Fatal` 或 `FAIL`，不能单靠退出码判断；旧版 ModelSim 遇到 `$stop` 时也可能返回 0。

## 剩余交付条件

- A 已实现 `event_overflow`、`param_overflow` 及事件溢出静音恢复；C 的仿真已接入真实状态口。正式合并前需协调 A/C 对公共头文件与接口文档的并行改动。
- C 已新增独立乐器顶层、J13 管脚映射、时序约束和整机 bitstream。`synth_top` 仍是已上板的固定音源版本。
- 当前测试验证数据链的逻辑行为；物理键盘上板还需要核实排针位置、电压及 8 线键盘顺序。
- A 当前仅一声部，16 键场景验证事件完整性，不代表已支持 16 音同时发声。
