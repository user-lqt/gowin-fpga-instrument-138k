# 工具链命令行操作手册（Gowin 云源软件）

> 归属：成员 C 维护。本文记录**已在本机实测验证**的命令行流程，用于免 GUI 的综合、布局布线、生成 bitstream 与烧录。
> 所有标 ✅ **已实测** 的命令都是我在本机真跑过的；标 ⬜ **待验证** 的会在第一次完整构建时补齐。

---

## 1. 本机环境（已核实）

| 项 | 值 |
|---|---|
| IDE 安装目录 | `E:\Gowin\Gowin_V1.9.12_x64` |
| 命令行控制台 | `E:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe` ✅ **实测可运行** |
| 烧录命令行 | `E:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe` ✅ **存在** |
| 器件库 | `E:\Gowin\Gowin_V1.9.12_x64\IDE\data\device\` |
| 138K 器件库 | `GW5AST-138B`、`GW5AST-138C` ✅ **两个版本都在** |
| 138K 封装 | `PBGA484A.json`（对应 IDE 里的 **PBG484A**） ✅ |
| 许可文件 | `E:\Gowin\gowin_E_381868299D16.lic`（教育版，2026-09-20 生成） ✅ |
| 许可配置 | `IDE\bin\gwlicense.ini` → 指向上面那个 `.lic` |
| 版本 | **V1.9.12**（满足 138K 的门槛：教育版 ≥1.9.9 / 商业版 ≥1.9.11.03） |
| Tcl 版本 | 8.6.4 |

> ⚠️ 许可文件是 `gowin_E_*.lic`（**E = 教育版**）。教育版支持 138K，但**不是商业版**。
> 若遇到"器件不支持"或"资源受限"类报错，再切商业版（官网申请，或 Sipeed 浮动服务器 `106.55.34.119:10559`）。

---

## 2. 基本用法

命令行控制台接受一个 Tcl 脚本：

```powershell
& "E:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" <脚本.tcl>
```

**⚠️ 脚本文件必须是无 BOM 的 UTF-8**。用 PowerShell 写脚本时不要用 `Set-Content -Encoding UTF8`（PS 5.1 会加 BOM，导致首字符乱码报 `invalid command name`）：

```powershell
[IO.File]::WriteAllText("script.tcl", $tclContent, [Text.UTF8Encoding]::new($false))
```

**⚠️ 相对路径以「当前工作目录」为基准**，不是脚本所在目录。脚本里显式 `cd` 或写绝对路径最稳。

---

## 3. 可用命令清单（已探测）

`gw_sh` 支持的工程相关命令：

| 命令 | 用途 | 状态 |
|---|---|---|
| `create_project` | 创建工程 | ✅ 实测 |
| `open_project` | 打开已有工程 | ✅ 命令存在 |
| `set_device` | 指定器件 | ✅ 实测 |
| `add_file` | 添加源文件/约束 | ✅ 命令存在（无 `add_files`） |
| `set_option` | 设置工程选项 | ✅ 命令存在 |
| `run <process>` | 运行构建流程 | ✅ 命令存在 |
| `create_ipc` / `read_ipc` / `get_ips` / `write_ip_tcl` | IP 核生成 | ✅ 命令存在 |
| `gao_sh.exe` | 在线逻辑分析仪命令行 | ✅ 可执行文件存在 |

**没有** `get_device` / `get_project` / `get_part_number` 这类查询命令。

---

## 4. 实测通过的语法

### 4.1 创建工程（138K 已实测成功）

```tcl
create_project -name synth_top -dir . \
    -pn GW5AST-LV138PG484AC1/I0 \
    -device_version B -force
```

**实测输出**：`create_project OK` —— 工程目录、`src/`、`impl/`、`.gprj` 均已生成。

**关键点：`-device_version` 必须给。** 只用 `-pn` 会报：

```
there are more than one device named GW5AST-LV138PG484AC1/I0, please specify its name as well
```

因为 `GW5AST-138B` 与 `GW5AST-138C` 两套器件库都在。**B 还是 C 由实物丝印决定。**

### 4.2 添加文件

```tcl
add_file ../rtl/common/reset_sync.v
add_file ../constraint/tang_mega138k.cst
```

### 4.3 运行构建流程

```tcl
run syn            # 综合
run pnr            # 布局布线
run all            # 全部
```

`run -h` 的帮助原文：*Available processes are: `syn` for synthesis; `pnr` for place&route; `all` for all the processes.*

> ⬜ **待验证**：`run all` 是否会一路走到生成 bitstream；若不能，需要补 `bitstream` 之类的动作。
> ⬜ **待验证**：综合报告、时序报告、资源报告的输出路径（预期在 `impl/pnr/` 下）。

---

## 5. IP 核怎么处理（PLL / CLKDIV / ROM）

`create_ipc` **只生成空壳**，不含参数配置：

```
create_ipc -name <ip名> -dir <路径> -language verilog -module_name <模块名> -file_name <文件名>
```

**正确的做法是 `read_ipc`：用一个已配置好的 `.ipc` 文件生成 IP。**

```tcl
read_ipc ../ip/gowin_pll/gowin_pll.ipc
```

**推荐路线**：从 Sipeed 官方 138K 例程里抄 `.ipc` 作为起点，只改分频参数：

| 需要的 IP | 参考来源（官方例程 audio_i2s） | 我们要改的参数 |
|---|---|---|
| `Gowin_PLL` | `eda_proj/src/gowin_pll/gowin_pll.ipc` | 输出频率：100 MHz + 12.288 MHz |
| `Gowin_CLKDIV` | `eda_proj/src/gowin_clkdiv/gowin_clkdiv.ipc` | 分频比：/4（得 3.072 MHz） |
| `Gowin_OSC` | `eda_proj/src/gowin_osc/gowin_osc.ipc` | 用于"没有外部晶振"时的降级方案 |
| ROM 波形表 | `eda_proj/src/rom_wave_sine.v` | 换成我们自己的波表 |

官方例程地址：<https://github.com/sipeed/TangMega-138K-example>

---

## 6. 烧录

```powershell
& "E:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe" <参数>
```

> ⬜ **待验证**：`programmer_cli.exe` 的具体参数格式（`-h` 输出待抓取）。
> 板子需要**连接板载 USB 下载口**，且**按住 PWR 键 2 秒开机**才能被识别。

**烧 Flash** 用官方推荐模式（比 SRAM 下载更可靠）：
```
exFlash Erase, Program through GAO-Bridge 5A
```

---

## 7. 我能做 / 我不能做

| 事项 | 能否 |
|---|---|
| 写 RTL、testbench、约束文件 | ✅ |
| 命令行综合 / 布局布线 / 时序与资源报告 | ✅ 已验证工具可用 |
| 生成 IP 核（PLL/CLKDIV/ROM） | ✅ 通过 `.ipc` 路线 |
| 生成 bitstream | ⬜ 待第一次完整构建验证 |
| 命令行烧录 | ⬜ 待接上板子验证 |
| 操作 IDE **图形界面** | ❌ 做不到（无法点击窗口） |
| 操作**逻辑分析仪 / 示波器软件** | ❌ 需要人工 |
| 判断**听感好不好** | ❌ 需要人耳 |
| **接板子、插线、查丝印** | ❌ 必须人来 |

---

## 8. 标准构建脚本（待第一次构建后补全）

预期最终形态（`tools/build.tcl`）：

```tcl
# 用法：gw_sh.exe tools/build.tcl
set ROOT [file normalize [file join [file dirname [info script]] ..]]
cd $ROOT

create_project -name synth_top -dir $ROOT/project \
    -pn GW5AST-LV138PG484AC1/I0 -device_version B -force

# IP
read_ipc $ROOT/ip/gowin_pll/gowin_pll.ipc
read_ipc $ROOT/ip/gowin_clkdiv/gowin_clkdiv.ipc

# RTL
add_file $ROOT/rtl/common/reset_sync.v
foreach f [glob -nocomplain $ROOT/rtl/system/*.v]     { add_file $f }
foreach f [glob -nocomplain $ROOT/rtl/audio_core/*.v] { add_file $f }
foreach f [glob -nocomplain $ROOT/rtl/input/*.v]      { add_file $f }
add_file $ROOT/project/synth_top.v
add_file $ROOT/constraint/tang_mega138k.cst
add_file $ROOT/constraint/tang_mega138k.sdc

run all
```

> **注意**：`*.vh` 头文件用 `add_file -type verilog` 单独加，或确保 `event_defs.vh` 与 RTL 在同一 `include` 路径下。

---

## 9. 待办

- [ ] 第一次完整构建，验证 `run all` 能否产出 bitstream
- [ ] 抓取 `programmer_cli.exe -h` 的参数格式
- [ ] 从官方例程导出 `gowin_pll.ipc` / `gowin_clkdiv.ipc` 作为起点
- [ ] 把 `tools/build.tcl` 落地并提交
- [ ] 板子上电识别验证（需硬件）
