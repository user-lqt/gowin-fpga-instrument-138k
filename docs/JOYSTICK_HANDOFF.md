# joystick 分支交接说明（2026-10-04）

本分支在 `shuyou` 双 EC11 版本上加入 MCP3008 和双轴摇杆输入。当前已完成
ADC SPI、CH0/CH1/CH2 轮询、摇杆平均/中心死区以及公共参数输出；未宣称
弯音和调制已经产生声音。

## 物理接线

| MCP3008 | FPGA逻辑 | J13 | FPGA球位 |
|---|---|---:|---|
| 10脚 CS/SHDN | `adc_cs_n` | 24 | A18 |
| 13脚 CLK | `adc_sclk` | 25 | D15 |
| 11脚 DIN | `adc_mosi` | 26 | D14 |
| 12脚 DOUT | `adc_miso` | 27 | D16 |

MCP3008 VDD、VREF 接 3.3V；AGND、DGND 共地。摇杆 VCC=3.3V、GND=GND、
VRx→CH1、VRy→CH2；FSR 分压节点→CH0。Z/SW 暂不接 FPGA，确认实物按下
与地短接后再另行分配数字 GPIO。J13-11 是5V，禁止作为任何GPIO或上拉。

当前既有接线保持不变：EC11_A=A21/B21/B18，EC11_B=C17/D17/E19，24键、
RGB屏和音频线均不变。MCP3008与FPGA必须共地，模块若带外围电路以实物丝印
和原理图为准，不照搬裸PDIP脚号。

## B 已完成

- `mcp3008_spi.v`：Mode 0、单端命令、null bit、B9..B0接收；默认约512kHz。
- `mcp3008_sampler.v`：CH0、CH1、CH2循环采样。
- `joystick_control.v`：4次平均、中心512初值、死区32初值。
- X轴输出 `PARAM_PITCH_BEND=2`，中心为0，约±8192；Y轴输出
  `PARAM_MODULATION=3`，中心为0，幅度0..65535。
- ADC事件进入三生产者参数队列，和双 EC11 更新共存。
- 仿真 `tb_mcp3008_spi`、`tb_joystick_control` 通过；完整回归已覆盖旧键盘、
  双 EC11、屏幕和音频链路。

工程入口：`tools/build_instrument_24_rgb.tcl`。当前生成文件：
`project/instrument_24_rgb_top/impl/pnr/instrument_24_rgb_top.fs`。
重新构建命令：

```powershell
& 'E:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe' tools/build_instrument_24_rgb.tcl
```

## 成员 A 必须完成

1. 在 `rtl/audio_core/audio_core.v` 中接收 `PARAM_PITCH_BEND=2`，把摇杆 X
   映射到音高弯音；中心值应保持原音高，方向和最大偏移用实测/听感确认。
2. 接收 `PARAM_MODULATION=3`，把摇杆 Y 映射到颤音或团队确定的调制目标；
   0 必须表示关闭/无调制。
3. 处理参数更新与 NOTE_ON/NOTE_OFF 的时序关系，不阻塞键盘和音频 sample_tick；
   明确多声部是全局弯音还是逐声部弯音。
4. 为中心、左端、右端、死区和参数突变增加仿真，提交声音/数值证据。当前
   音频核心遇到 ID=2/3 会安全忽略，直到 A 完成上述接入。

## 成员 C 必须完成

1. 复核本分支 `.cst` 中 A18/D15/D14/D16 的 Bank2 电压和 J13 方向，确认与
   31005 实物丝印一致；不得复用键盘、EC11、RGB或音频引脚。
2. 复核 MCP3008 的 CS 空闲高、SPI Mode 0、约512kHz时序和 FPGA 3.3V电平；
   上板先用 CH0 接0V、约1.65V、3.3V验证读数接近0/512/1023。
3. 将 A 的弯音/调制实现合并到系统工程，验证 ADC 轮询不影响键盘、双 EC11、
   RGB刷新和 I2S；处理 parameter FIFO 溢出并保留可观察状态。
4. 实测摇杆中心、端点、方向和噪声，更新 `CENTER_X/Y`、`DEADZONE` 及滤波；
   确认 FSR406B 分压读数后再确定压力映射。最终由 C 做整机烧录和阶段验收。

## 当前限制

当前 `.fs` 已包含 ADC 引脚和采样逻辑，但音频核心尚未接收 ID=2/3，摇杆
转动暂时不会改变声音；这是待 A 完成的明确事项。现有工程仍为4复音，32复音
与本次 ADC 接入无关。高云已有参考时钟布线、音频位宽等历史警告，C 合并时
按最新时序报告复核。
