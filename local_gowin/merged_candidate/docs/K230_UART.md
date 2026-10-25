# K230 独立 UART 参数与触屏音符接口（V4.9）

本次源码以 `b0fa528` 的完整滑音整合版为底座，工程入口为 `project/instrument_fixed_top/instrument_fixed_top.gprj`。没有修改根目录中的成员独立工程。

完整接线、K230 程序运行、协议示例和实物测试步骤见 [`../../../k230_gesture_test/FPGA_UART_WIRING.md`](../../../k230_gesture_test/FPGA_UART_WIRING.md)。

- 新输入 `k230_uart_rx`：J13-35 / C20 / SDRAM0_BA1，Bank 2，3.3 V，上拉。
- K230 TX 接该输入，GND 与 FPGA 共地；K230 外部 5 V 供电，电源正极无需跨板互连。
- 独立接收器保留 BLE 的 C18/C19。K230 使用 12 针 GPIO 排针第 5 脚 IO32 / UART3 TX，第 4 或第 7 脚 GND；第 3 脚 IO33 RX 不接。
- 115200、8N1；二进制帧 `A5 CMD A B XOR`，校验字节为前四字节异或。
- `B4` 音量为 0..100%，5% 一档；`B5` 音色为 0 钢琴、1 吉他、2 编钟。
- `90 NOTE VELOCITY` 按下音符，`80 NOTE 00` 松开，音符和力度范围 0..127；`90 NOTE 00` 同样视为松键。第三页使用 C4～C5 的 8 个自然音、固定力度 100、单指单音。
- `B6 NOTE 00` 只刷新当前触屏音符的存活时间，不重新触发包络。K230 每 250ms 保活，FPGA 1 秒超时自动松键；参数指令及其他音符的保活不会延长当前音符。迟到的保活不会启动新音。
- `k230_control_rx.v` 新增音符事件输出；顶层用 `performance_event_merge` 合并 K230/BLE，再进入已有演奏队列。滑动换键先发 NOTE_OFF 再发 NOTE_ON；如果旧 NOTE_OFF 丢失，接收器会在新音前主动释放旧音。实体键盘、BLE 与触屏共用按音高管理的声部，避免不同来源同时按同一个音。
- 复用现有 `ble_uart_rx` 的独立实例接收字节，由 `k230_control_rx.v` 校验参数，再接入 `encoder_control.v`/`parameter_manager.v`，与实体编码器共用状态和音频参数队列。
- `ENABLE_REMOTE` 默认 0，旧实例可保持原行为；完整顶层显式启用。远程音量与本地音色同时发生时，分别保留；远程音色与本地音量同周期也按次序发布。
- 无手、暂停或断线保持参数；启动不覆盖 FPGA 的设定。当前单向发送，无 ACK 或参数回读，K230 数值不代表 FPGA 已确认。

## 验证

在仓库 `k230_gesture_test/` 中运行：

```powershell
python -m unittest -q test_fpga_uart.py test_static_control_logic.py test_preprocess_cache.py test_single_file.py test_touch_control.py test_uart_header.py
```

56 项检查通过：原手势与参数控制、UART3 引脚、单文件部署、触屏页面隔离、快速轮询、8 键按下/松开/滑动/切页、保活与退出释放、原始帧校验及透明 UI。

在本 FPGA 工程根目录运行（安装 Icarus 后按需替换路径）：

```powershell
.\tools\verify_k230.ps1 -IcarusBin 'C:/iverilog/bin'
```

已通过：

- `tb_k230_control`：实际串口比特流的 21 档音量和三种音色，错误校验/保留字节/越界/非法命令过滤，半包超时与恢复，编码器接管和同周期参数竞争。
- `tb_k230_notes`：音符按下与释放、换音时补松键、保活不重触发、断线超时、迟到/错误音符保活、错误帧和参数/音符隔离。
- `tb_volume_mapping`：128 档 UI 到音频增益映射与复位。
- `tb_master_volume`：三种音色的零音量静音及增益回归。
- `tb_ble_song_uart`：原蓝牙串口、音符和曲目指令回归。
- 完整 `instrument_24_rgb_top` 结构编译，PLL 使用仿真桩。

为兼容本机 Icarus 13，只前移了 `oscillator.v` 中 `multiply_product` 的声明，表达式和运算不变。

**本次没有运行 Gowin 综合或布局布线，没有生成新固件。** 用户已确认 UART3 外部回环 10/10 通过，参数诊断能改变 FPGA 的音量与音色；V4.9 触屏琴键尚未上板验证。现有 `prebuilt/instrument_fixed_top.fs` 是 10 月 18 日版本，不含这些源码更新。必须重新构建 FPGA 工程后才可验证第三页发声。
