# K230 独立 UART 音量与音色接口

本次源码以 `b0fa528` 的完整滑音整合版为底座，工程入口为 `project/instrument_fixed_top/instrument_fixed_top.gprj`。没有修改根目录中的成员独立工程。

完整接线、K230 程序运行、协议示例和实物测试步骤见 [`../../../k230_gesture_test/FPGA_UART_WIRING.md`](../../../k230_gesture_test/FPGA_UART_WIRING.md)。

- 新输入 `k230_uart_rx`：J13-35 / C20 / SDRAM0_BA1，Bank 2，3.3 V，上拉。
- K230 TX 接该输入，GND 与 FPGA 共地；K230 外部 5 V 供电，电源正极无需跨板互连。
- 独立接收器保留 BLE 的 C18/C19。接口只接收参数，K230 不产生琴键音符。
- 115200、8N1；二进制帧 `A5 CMD VALUE 00 XOR`。
- `B4` 音量为 0..100%，5% 一档；`B5` 音色为 0 钢琴、1 吉他、2 编钟。
- 复用现有 `ble_uart_rx` 的独立实例接收字节，由 `k230_control_rx.v` 校验参数，再接入 `encoder_control.v`/`parameter_manager.v`，与实体编码器共用状态和音频参数队列。
- `ENABLE_REMOTE` 默认 0，旧实例可保持原行为；完整顶层显式启用。远程音量与本地音色同时发生时，分别保留；远程音色与本地音量同周期也按次序发布。
- 无手、暂停或断线保持参数；启动不覆盖 FPGA 的设定。当前单向发送，无 ACK 或参数回读，K230 数值不代表 FPGA 已确认。

## 验证

在仓库 `k230_gesture_test/` 中运行：

```powershell
python -m unittest -q test_fpga_uart.py test_static_control_logic.py test_preprocess_cache.py
```

42 项检查通过：手势到三种音色的实际映射、原始字节校验、变化才发送、暂停/丢手策略、音量平滑和分档、预处理缓存及叠加 UI。

在本 FPGA 工程根目录运行（安装 Icarus 后按需替换路径）：

```powershell
.\tools\verify_k230.ps1 -IcarusBin 'C:/iverilog/bin'
```

已通过：

- `tb_k230_control`：实际串口比特流的 21 档音量和三种音色，错误校验/保留字节/越界/非法命令过滤，半包超时与恢复，编码器接管和同周期参数竞争。
- `tb_volume_mapping`：128 档 UI 到音频增益映射与复位。
- `tb_master_volume`：三种音色的零音量静音及增益回归。
- `tb_ble_song_uart`：原蓝牙串口、音符和曲目指令回归。
- 完整 `instrument_24_rgb_top` 结构编译，PLL 使用仿真桩。

为兼容本机 Icarus 13，只前移了 `oscillator.v` 中 `multiply_product` 的声明，表达式和运算不变。

**本次没有运行 Gowin 综合或布局布线，没有生成新固件，也未执行 K230/FPGA 实物 UART 联调。** 现有 `prebuilt/instrument_fixed_top.fs` 是 10 月 18 日版本，不含新增 UART 与 10 月 21 日滑音修改。
