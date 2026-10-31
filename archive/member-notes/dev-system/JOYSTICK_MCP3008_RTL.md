# MCP3008 + PS2 摇杆 RTL

本次新增链路已接入当前双 EC11 顶层；ADC 物理引脚已按最新分配加入 `.cst`。
旧双 EC11 `.fs` 不会自动改变，重新构建后才生成带 ADC 的新烧录文件。

## 模块

- `rtl/input/mcp3008_spi.v`：MCP3008 单端 Mode 0 SPI 主机。`start` 触发一次
  转换；`channel` 为 0..7；`busy`、`done` 和 `adc_data[9:0]` 是同步接口。
  默认 `CLK_DIV=12`，若音频时钟约12.288MHz，SCLK约512kHz。
- `rtl/input/mcp3008_sampler.v`：轮询 CH0、CH1、CH2，分别保存 FSR、VRx、VRy
  的10位结果。每次转换通过 `sample_valid/sample_channel` 通知。
- `rtl/input/joystick_control.v`：CH1平均4次后做中心/死区处理，输出
  `PARAM_PITCH_BEND=2`（有符号弯音，中心0）和 `PARAM_MODULATION=3`
  （Y轴调制深度，中心0）。参数进入整机三生产者队列；现有音频核心仍忽略
  弯音和调制 ID，成员 A 接入算法后才会产生声音变化。

## 摇杆接线假设

该模块按资料中的被动双轴电位器处理：VCC=3.3V、GND=系统地、VRx→MCP3008
CH1、VRy→CH2。Z/SW 不接 MCP3008；确认实物按下与地短接后，才另接3.3V GPIO
并加上拉。资料里的 Arduino A0/A1/D7 不是 FPGA 引脚分配。

MCP3008 裸 PDIP-16：CH0脚1、CH1脚2、CH2脚3、DGND脚9、CS脚10、DIN脚11、
DOUT脚12、CLK脚13、AGND脚14、VREF脚15、VDD脚16。VDD/VREF=3.3V，
AGND/DGND共地；VDD-DGND和VREF-AGND附近各放100nF。FSR分压接CH0，
其电压必须保持0..3.3V。若买的是模块，先按模块丝印/原理图确认，不能照搬
裸芯片脚号。

## 需要实测的事项

摇杆资料中150kΩ只是示意值；先测实际电位器阻值和3.3V端点电压。高源阻抗
可能造成MCP3008采样建立误差；先用10nF并在切换后丢弃首样本，若仍不稳再加
电压跟随器。`CENTER_X/Y=512` 和 `DEADZONE=32` 是可改的初始值，必须用
实测中心值校准。FSR406B与FSR402曲线不同，不能复用压力曲线。

## 仿真

```powershell
powershell -ExecutionPolicy Bypass -File tools/verify_strike_expression.ps1
```

其中 `tb_mcp3008_spi` 检查CH0=0、CH1=512、CH2=1023的数据对齐和CS时序；
`tb_joystick_control` 检查4次平均、中心死区、有符号X弯音和Y调制输出。
当前工程回归中这两项均通过。正式分配为：ADC_CS=J13-24/A18，
ADC_SCLK=J13-25/D15，ADC_MOSI=J13-26/D14，ADC_MISO=J13-27/D16。
四根线均为3.3V逻辑，MCP3008与FPGA共地；接线后先做0V/1.65V/3.3V验证。
