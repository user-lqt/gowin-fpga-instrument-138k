# MCP3008 + PS2 摇杆 RTL

2026-10-07 更新，交付分支为 `integration/c-stage3`。摇杆 X 已接入当前
双音色、32 声部、FSR 颤音整机。本文描述当前实现；10 月 4 日的交接说明
保留在 `JOYSTICK_HANDOFF.md`，其中“音频尚未接收参数”属于历史状态。

当前用户的摇杆模块尚未接上，顶层默认 `ENABLE_JOYSTICK=0`，仅采 CH0。
本次交付源码和仿真，尚未为启用摇杆的配置生成新的可烧录 `.fs`。

## 模块

- `rtl/input/mcp3008_spi.v`：MCP3008 单端 Mode 0 SPI 主机。`start` 触发一次
  转换；`channel` 为 0..7；`busy`、`done` 和 `adc_data[9:0]` 是同步接口。
  默认 `CLK_DIV=12`，若音频时钟约12.288MHz，SCLK约512kHz。
- `rtl/input/mcp3008_sampler.v`：启用摇杆时轮询 CH0/CH1/CH2，分别保存
  FSR、VRx、VRy 的 10 位结果。每次转换由 `sample_valid/sample_channel`
  通知；空位校验失败则发布 `sample_error`，与有效样本互斥。
- `rtl/input/joystick_control.v`：两轴独立平均 4 次，完成一组后发布一拍
  参数事件。中心默认 512，包含端点的死区为 480～544。死区外扣除死区
  后连续映射，各方向按距 ADC 端点的剩余量程分别缩放，支持修改中心值。
- X 输出 `PARAM_PITCH_BEND=2`：ADC 0 对应 -8192、1023 对应 +8191、
  中心为 0，音频约为降低/升高 2 个半音，全局作用于当前声部。
  音频核心已有逐采样平滑，避免参数突变直接跳音高。
- Y 输出 `PARAM_MODULATION=3`：中心为 0，两端为 65535。当前顶层只把
  摇杆 X 事件送入参数队列 C；Y 事件被过滤，FSR 独占队列 D 的颤音深度，
  避免两种输入互相覆盖。Y 的后续用途仍待确定，当前拨动 Y 不改变声音。
- X/Y 通信失败时分别清空本轴的部分平均及控制值；此前值非零时发布一次
  零参数。恢复通信后重新收齐 4 个样本。CH0 的样本和错误不影响摇杆。
  此处理针对 SPI 空位校验失败，无法检出所有硬件故障或单轴模拟线断开。

共享转换启动间隔为 4096 个 12.288 MHz 时钟；启用三通道轮询时每轴约
1 kS/s，摇杆每 4 ms 完成一组平均。复位清除滤波、弯音和调制值。

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

摇杆资料中 150 kΩ 只是示意值；先测实际电位器阻值和 3.3 V 端点电压。
高源阻抗可能造成 MCP3008 采样建立误差；若实测出现串扰，应评估输入滤波、
切换后丢弃首样本或电压跟随器。当前采样器没有丢弃首样本的逻辑。
`CENTER_X/Y=512` 和 `DEADZONE=32` 是初始值，应按实测中心校准；在顶层
的 `u_joystick_control` 实例上覆写这些参数即可，校准不会修改 FSR 标定。

## 启用与上板操作

1. 接好摇杆 VCC/GND/VRx/VRy，VCC 使用 3.3 V。X/Y 模拟线不直连 FPGA。
2. 将 `project/instrument_24_rgb_top.v` 的 `ENABLE_JOYSTICK` 默认参数改为 1。
   未接模块时保持 0，避免悬空的模拟输入导致音高漂移。
3. 使用 `tools/build_fsr_measured_noguitar.tcl` 重新构建。脚本保留钢琴/编钟、
   排除吉他，并为重试创建独立工程目录，不覆盖旧固件。
4. FSR 不施压，只按住一个琴键。摇杆居中时保持原音高，X 往两端拨应连续
   降低/升高约 2 个半音，放手回中后恢复原音高；实际左右方向以模块安装为准。
5. 再压住 FSR，同时拨 X：弯音和颤音应共存。拨 Y 不应改变颤音深度。
   松琴键后正常进入尾音并停止，不产生额外音符。

当前模块没有自动居中校准，也没有接入摇杆 SW 按钮。

## 仿真

```powershell
.\tools\verify_fsr_vibrato.ps1 -TwoTimbres -Tests tb_joystick_control,tb_instrument_fsr_vibrato
```

`tb_joystick_control` 覆盖四次独立平均、交错通道、完整 0～1023 单调性扫描、
精确正负端点、中心/死区、非 512 中心标定、单拍事件、SPI 失败归零与恢复、
复位丢弃部分平均。`tb_instrument_fsr_vibrato` 检查真实 SPI 模型到整机音频：
X 正负弯音与 FSR 共存、Y 不覆盖 FSR、回中、ADC 失败撤销弯音/颤音、
双音色、松键停止、参数队列无溢出及采样期限。

正式分配为：ADC_CS=J13-24/A18，
ADC_SCLK=J13-25/D15，ADC_MOSI=J13-26/D14，ADC_MISO=J13-27/D16。
四根线均为3.3V逻辑，MCP3008与FPGA共地；接线后先做0V/1.65V/3.3V验证。

## 本次验证记录

2026-10-07：

- 摇杆单元测试通过：`sim/fsr_vibrato_build/20261007_190132/tb_joystick_control.log`。
- 启用摇杆的完整双音色整机仿真通过，覆盖上述共存、释放、故障与恢复：
  `sim/fsr_vibrato_build/20261007_190145/tb_instrument_fsr_vibrato.log`。
  ModelSim 复核也通过：`sim/joystick_integration_test_build/joystick_final.log`。
- Gowin V1.9.12 单独综合 `joystick_control` 通过；逻辑 1310、寄存器 98、
  BSRAM 0，含 3 个 MULTALU27X18 实例。综合估计 Fmax 为 20.666 MHz，
  本记录没有启用摇杆的整机布局布线结果，不能代替最终时序检查和上板测试。
  两处 EX3791 是 32 位计算结果写入 16 位输出的截断提示；端点与全范围
  单调性测试已验证当前参数下数值范围正确。

本机综合报告位于
`E:\GowinProjects\_tmp\joystick_synth_check_20261007_191016\impl\gwsynthesis\joystick_synth_check_20261007_191016_syn.rpt.html`。
日志、仿真库与综合产物留在本地，Git 只提交源码、测试、脚本与文档。
