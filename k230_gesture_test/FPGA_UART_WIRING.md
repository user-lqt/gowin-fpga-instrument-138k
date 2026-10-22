# K230 手势控制 FPGA：接口与接线 V4.4

本版完成 K230 发送端与 FPGA 独立接收通路。控制音量、音色；不通过 K230 生成音频，不发送琴键音符。FPGA 保留原有蓝牙、实体键盘、双编码器、FSR、摇杆和显示接口。

GitHub 下载入口：本目录为 K230 程序，FPGA 完整源码位于 [`../local_gowin/merged_candidate/`](../local_gowin/merged_candidate/)，工程入口为 [`instrument_fixed_top.gprj`](../local_gowin/merged_candidate/project/instrument_fixed_top/instrument_fixed_top.gprj)。下文 `E:\GowinProjects\...` 为原作者本机路径，克隆后以自己的仓库路径为准。

## 1. 接线：两根信号线，K230 外部 5 V 供电

K230 使用用户的外部稳压 5 V 电源，接模块规定的 5 V 电源入口；FPGA 继续使用原有供电。两块板的电源正极不用互连。

| K230 一侧 | FPGA Tang Mega 138K 31005 Rev1.3 底板 | 用途 |
|---|---|---|
| 外部 UART 接口的 TX | **J13 第 35 脚，FPGA 球号 C20** | K230 向 FPGA 发送音量、音色 |
| GND | **J13 第 12 脚 GND**，或板上其他 GND | 公共地参考 |
| UART RX | 暂不连接 | 本版只单向发送参数 |
| 外部供电 +5 V | 不接 FPGA 排针 | 只供给 K230 电源入口 |

这两根跨板线为 **TX 和 GND**。外部电源负极应与 K230 GND 相连，再通过上述 GND 线与 FPGA 共地。若 K230 通过配套 4 针线的 5 V/GND 供电，可分别连接外部电源 +5 V/负极。

串口使用 **3.3 V TTL**，不是 5 V 信号，也不是 RS-232。5 V 只能接 K230 规定的电源端，不能接 FPGA C20。优先按模块 TX/GND 标识找线；亚博串口教程图中的 `TXD/RXD` 是 **USB 转 TTL 一端**的标识，K230 TX 应接图中的 RXD（配套线为黄色），K230 RX 对应图中的 TXD（绿色）。若线材颜色不同，以实际模块标识为准。

J13 编号依据底板原理图，不按照片左右猜测；第 35 脚的网络为 `SDRAM0_BA1`，连接 `BANK2_C20`。第 12 脚为 GND；第 11 脚是 5 V，不能误接到信号上。确认实物底板版本为 31005 Rev1.3，且 J13-35 没有另接 SDRAM 等外设。

原蓝牙使用 C18/C19，本版增加独立 `k230_uart_rx`，无需拔掉 ESP32 的 TX。FPGA 的串口由逻辑实现，可按可用 GPIO 增加接收器；开发板上的 USB 下载/调试口不等于只有一路可用串口。

## 2. 音色对应

已核对当前整合顶层：`INSTRUMENT_COUNT(3)`、`ENABLE_GUITAR(1)`。

| K230 显示 | K230 列表位置 | FPGA 协议编号 |
|---|---|---|
| 钢琴 | 1/3 | 0 |
| 吉他 | 2/3 | 1 |
| 编钟 | 3/3 | 2 |

剪刀手进入音色页；点赞下一种，三指上一种。每次保持只切一次，到边界停止，不循环。音色名称会直接叠加在完整摄像头画面上。

## 3. K230 文件与运行

将以下三个文件通过 CanMV IDE 保存到板子的 `/sdcard/` 根目录，保留相同文件名：

1. `gesture_page_control_test.py`：V4.4 的识别、交互、透明文字界面。
2. `k230_fpga_uart.py`：UART 协议和参数发送器，调用亚博固件自带 `ybUtils.YbUart`。
3. `gesture_fpga_control.py`：联机运行入口。

在 IDE 运行 **`gesture_fpga_control.py`**，应看到 `K230 FPGA UART: 115200 8N1` 和 `PALM HEIGHT V4.4`。直接运行 `gesture_page_control_test.py` 仍是单独屏幕演示，不启用 UART。

不需要自行更改 FPIOA 或猜 GPIO 编号；这里采用亚博 `02.Basic/05.uart.py` 使用的同一个外部 UART 接口与固件库。不要把本工程接到 K230 USB 插座当成 TTL 串口。模型和屏幕设置沿用上一版。

音量仍按 **0%、5%、10%……100%**；500 ms 平滑、每秒最多 20 个百分点的内部跟随速度和档位防抖保留。单指选音量页，张掌保持确认后抬高/放低调节。握拳、无手或换成非张掌姿势停止调节，保留音量，不发送静音。

只有手势确实改变数值时发送参数。启动不强制把 FPGA 改成 50%/钢琴，切页不发送参数，也不定时重复旧值覆盖编码器。K230 是发送端：屏幕数值代表它自己的控制值，尚无 FPGA 应答，不能作为接收成功指示；直接用 FPGA 编码器修改参数，也不会反向更新 K230。首次联调以 FPGA 屏幕和实际声音为准。FPGA 复位后，重新做一次调整即可发送新值。

## 4. FPGA 源码与工程入口

本地已集成目录：

```text
E:\GowinProjects\synth_top_legato_glide\local_gowin\merged_candidate\
```

当前工程入口：

```text
project/instrument_fixed_top/instrument_fixed_top.gprj
```

修改和新增文件：

| 文件 | 内容 |
|---|---|
| `rtl/input/k230_control_rx.v` | 独立 UART 接收与命令检查，复用现有 UART 解码模块 |
| `project/instrument_24_rgb_top.v` | 新增 `k230_uart_rx`，接入现有参数管理器 |
| `rtl/input/encoder_control.v` | 可选远程参数输入，旧工程默认关闭 |
| `rtl/ui/parameter_manager.v` | 统一保存编码器与 K230 设置，生成原音频参数和 LCD 状态 |
| `constraint/instrument_24_rgb_mega138k.cst` | C20/J13-35，3.3 V 输入上拉 |
| `constraint/instrument_24_rgb_mega138k.sdc` | 新串口异步输入约束 |
| `project/instrument_fixed_top/instrument_fixed_top.gprj` | 增加接收模块源文件 |
| `tools/build_velocity.tcl` | 将接收模块加入源码清单 |
| `rtl/audio_core/oscillator.v` | 仅将 `multiply_product` 声明前移，兼容当前 Icarus；运算不变 |
| `sim/audio_core_tb/tb_k230_control.v` | 实际 UART 比特流、参数与编码器交接仿真 |
| `tools/verify_k230.ps1` | 本接口及关联回归入口 |

参数进入同一管理器，所以远程修改后 FPGA LCD、声音参数、编码器下一步的起点一致。音量同周期竞争优先采用远程值；远程音色和本地音量同时到达时，会依次发送两个参数，不丢掉另一个。

**按用户要求，本次不运行布局布线，也未运行 Gowin 综合，不生成新 `.fs`。既有固件不会自动具备这个接口。** 后续需要构建时，使用上面已经更新的 `instrument_fixed_top.gprj`；其他历史 `.gprj` 尚未逐一添加新增接收模块。

## 5. 五字节协议

串口：**115200 baud，8 数据位，无校验，1 停止位**，低位先发，空闲高电平。

```text
A5 CMD VALUE 00 CHECKSUM
CHECKSUM = A5 XOR CMD XOR VALUE XOR 00
```

| CMD | VALUE | 作用 |
|---|---|---|
| B4 | 0、5、10……100 | 设置主音量百分比 |
| B5 | 0、1、2 | 钢琴、吉他、编钟 |

示例十六进制字节（没有空格字符或换行符）：

| 操作 | 数据 |
|---|---|
| 静音 | `A5 B4 00 00 11` |
| 音量 25% | `A5 B4 19 00 08` |
| 音量 50% | `A5 B4 32 00 23` |
| 钢琴 | `A5 B5 00 00 10` |
| 吉他 | `A5 B5 01 00 11` |
| 编钟 | `A5 B5 02 00 12` |

FPGA 拒绝错误校验、错误保留字节、超范围及不满足 5% 步进的音量。音量映射为 `UI = round(percent × 127 / 100)`，再使用原来的 16 位音频增益映射，保留去爆音平滑；顶层原有半幅余量不变，因此协议 100% 表示原编码器的最大档位。串口断开或空闲不自动改音量和音色。

## 6. 后续上板联调顺序

以下步骤在 FPGA 完成后续构建并烧录后执行，本次先交付源码。

1. 两板断电，按表连接 TX/GND；K230 外部 5 V 供电，两板共地。
2. FPGA 烧录包含新增接口的固件，确认原键盘/声音正常。
3. 将 `uart_parameter_smoke_test.py` 也复制到 `/sdcard/` 并运行；此程序无需摄像头或模型，会每两秒发送一个参数。按住一个实体琴键，观察静音 → 25% → 50% → 25%，再依次钢琴 → 吉他 → 编钟 → 钢琴。最终保留 25%/钢琴。
4. 参数测试通过后停止它，运行 `gesture_fpga_control.py`，测试手掌高度音量与三种音色。
5. 转动/按下 EC11_A，确认从远程设定值继续变化；随后再次做手势，确认仍可接管。蓝牙音符输入可以继续使用。

当前完成了电脑端检查及 RTL 仿真，没有执行 K230/FPGA 实物串口联调或布线后时序验收。

## 7. 备份与交接

原作者本机的旧文件保存在 `backups/before_fpga_uart_20261022/`，本机交接包中的 `fpga_interface/` 按工程相对路径保存本次 FPGA 文件；这两份副本不入 Git。GitHub 直接维护 `../local_gowin/merged_candidate/` 中的完整工程。合并到不同分支时需比较差异，不能直接覆盖队友的新顶层。

本次接线核对依据：本地亚博串口教程与 31005 Rev1.3 底板原理图第 7、19 页。
