# FPGA 音乐合成与分析仪：提交冻结版

## 当前副本：行内部上拉测试

此副本的八条行线已由 `PULL_MODE=NONE` 改为 `UP`，其余 FPGA 源码和引脚不变。
新测试固件已构建并通过物理属性与时序检查，单独保存为
`bitstream/integrated_instrument_64_row_pullup.fs`，尚未烧录。
SHA256：`6EDA1725FD4F5DA1ACD33EACE5C261872AF24064203C493C64E98BDA5BE576A2`。
下文 `bitstream/integrated_instrument_64.fs` 仍是原冻结版本，保留用于回退，不含行上拉修改。
本次改动、失败重试记录与复测要求见 `docs/ROW_PULLUP_TEST.md`。

版本日期：2026-10-31。本目录是独立工程，不需要原工作区或历史候选目录。
用于匹配现有开发板、800×480 屏幕及接线，不是通用开发板固件。

## 直接烧录

- 文件：`bitstream/integrated_instrument_64.fs`
- SHA256：`47BCF4691F686C3D37A95079DA622D7C526FFE9051FF8F47FBB9B646D56FB794`
- 器件：`GW5AST-LV138PG484AC1/I0`，工程器件系列 `GW5AST-138C`。
- 本包仅保留 **64复音工程和已完成综合、布线及时序检查的64复音烧录文件**。
- 使用 Gowin Programmer 核对器件和下载器后手动下载，详见 `docs/PROGRAMMING.md`。本包不会自动烧录。

此文件与用户认可版本逐字节相同。本次迁移没有修改硬件运算或重新综合；仅补充注释、清理未使用历史文件和增加便携工具。64版RTL词法及综合指令不变，其他原工程输入逐字节一致，核查见 `reports/migration_audit.json`。按交付要求已移除独立32复音工程。

## 工程入口

- 64复音：`project/integrated_instrument_64/integrated_instrument_64.gprj`
- 源码、约束、HEX/VH数据表及FFT第三方许可证均在各工程内部。
- `reports/`：合格版本资源、时序、引脚及迁移审计；`docs/simulation/`：RTL仿真演示，不是上板照片。
- `tools/`：中文PC采集分析软件、校验和有时限的构建脚本；`k230/`：板端控制程序和主机协议测试。
- `verification/`：波形量程、15/64帧消抖、实际扫描、复音控制和共享振荡器回归。

## 校验与重建

在本目录运行：

```powershell
python -B tools/verify_package.py
python -m pip install -r requirements.txt
python -B tools/acceptance_gui.py
```

完整顶层结构编译和重点回归需要 Icarus Verilog，加入PATH后：

```powershell
python -B tools/verify_package.py --rtl
```

原工具版本为 Gowin V1.9.12。安装对应Windows工具和许可证后：

```powershell
python -B tools/build_project.py --gw-sh "你的Gowin安装目录/IDE/bin/gw_sh.exe"
```

仅构建64版。综合硬上限20分钟、布局布线硬上限30分钟，失败即停止，进程树和睡眠中断受保护。新产物与日志在 `builds/` 和对应工程 `impl/`，**不会覆盖本包冻结的 `bitstream/`**。已有构建输出需先自行归档，脚本拒绝直接覆盖。不要并行启动多个物理构建。

不同工具版本、许可证或布局随机性可能导致不同位流；不能假设重建SHA与冻结文件一致。冻结HEX已完整提供，编译不需要旧版字模生成工具或额外字体。

## 结果边界

原合格构建：综合859.344秒，布局布线1231.279秒；Setup/Hold违例均0。
Logic97251/138240，CLS57199/69120，BSRAM326/340，DSP105/298。
按下消抖15帧、释放64帧、ROW_CYCLES307。

本包的校验不替代现场验收。48kHz LRCK、模拟DAC频谱、每路MUTE、真实按键延迟和K22力度仍应记录实测。K22硬击键锚点目前为临时响应修正，不应描述为完成实物标定。详见 `docs/FUNCTIONS.md` 和 `docs/ARCHITECTURE.md`。
