# 成员B当前完整工程（2026-10-15）

> 当前交接以 [2026-10-15交接说明](HANDOFF_B_20261015.md) 为准。已切换外置PCM5102A标准I2S，包含手机网页、下载曲谱和事件回传。用户最新反馈上板可发声；VOL显示000、下载后指引不更新、第二首换歌暂未修复，按用户要求等成员A合并后处理。下方2026-10-11内容为历史记录。

本分支提供当前板上使用工程的独立快照，供成员A参考。仓库根目录的历史工程保留；请使用下面的目录打开最新工程。

## 工程入口

- FPGA：`audio_velocity_32_two_timbres/project/instrument_velocity_32_two_timbres/instrument_velocity_32_two_timbres.gprj`
- FPGA顶层：`audio_velocity_32_two_timbres/project/instrument_24_rgb_top.v`
- 音频核心：`audio_velocity_32_two_timbres/rtl/audio_core/`
- 输入及力度：`audio_velocity_32_two_timbres/rtl/input/`
- 屏幕、系统与灯带：对应的 `rtl/ui/`、`rtl/system/`
- 硬件约束：`audio_velocity_32_two_timbres/constraint/`
- 仿真源码与工具：`audio_velocity_32_two_timbres/sim/`、`tools/`
- ESP-IDF工程：`esp32c3/bluetooth/`，完整FIX3代码在 `main/main.c`。
- 现有烧录文件：`audio_velocity_32_two_timbres/prebuilt/instrument_velocity_32_two_timbres.fs`，来自本地2026-10-11 15:07的布局布线输出。本次上传未重新生成。

FPGA平台为Tang Mega 138K、GW5AST-LV138PG484AC1/I0，使用Gowin v1.9.12；ESP为ESP32-C3、ESP-IDF v6.0。上传副本的Gowin工程引用已转换为相对路径，49个文件引用均检查存在。本地正在使用的原工程未改动。

## 当前功能

32复音钢琴/编钟、24键双触点逐键力度阈值、力度音量/泛音/起音动态、双EC11、800×480 RGB屏幕、滑音与延迟音效、32复音测试模式、FSR/MCP3008颤音、歌曲灯带指引、BLE转UART音符输入。详细功能及接线见工程目录README_TWO_TIMBRES.md与docs/。

## 蓝牙接线与使用

ESP GPIO21 TX → FPGA C18 RX；ESP GPIO20 RX ← FPGA C19 TX；共地，3.3V逻辑。ESP使用USB Serial/JTAG作为日志控制台。

服务UUID：`6e400001-b5a3-f393-e0a9-e50e24dcca9e`。

002特征支持读取/写入/无响应写入；003特征支持读取/通知。完整UUID仅将服务中的001改为002或003。设备名FPGA-BLE-FIX3；排查版每次重启产生新地址，需要重新扫描连接。

手机选择002、HEX发送：

```text
A5 90 3C 64 6D  # 中央C NOTE_ON
A5 80 3C 00 19  # 中央C NOTE_OFF
```

实际发送不包含注释。帧为A5、命令、MIDI音符、力度、前四字节异或校验。文本形式的HEX命令也支持。003开启通知后可收到ESP的UART OK 5；它只确认ESP发送完成，FPGA TX当前为常高，没有实现接收确认。

## 验证边界

用户已报告手机发送NOTE_ON后实际发声，证明BLE→ESP→UART→FPGA→音频输出链路可用。NOTE_OFF需在声音仍响时观察释放/衰减，单独发送没有新声音并不能完整证明释放行为。本次上传仅做文件完整性与差异检查，未重新运行仿真、综合或布局布线；历史测试文件不代表本次重新通过。

K6存在实体硬件故障，后续指引曲目避开K6。构建缓存、临时仿真库与大型中间数据库不上传；可重建源码、配置和现有FPGA烧录文件均随快照提供。
