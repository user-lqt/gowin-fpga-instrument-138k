# 摇杆 X 弯音测试固件

日期：2026-10-15。用于验证 MCP3008 + PS2 双轴摇杆在当前 24 键 RGB 整机上的弯音。
交付分支：`feature/c-joystick-bend-test-20261015`。从已验证的基线提交
`841892c51a33f09fe9aa0f85c2a85b35575d8131` 创建，包含摇杆 RTL、SPI 采样、
音频弯音接口、仿真、启用配置的构建脚本及本次验证记录。
本次固件：`E:\GowinProjects\firmware\joystick_bend_two_timbres_20261015_195741.fs`。
SHA256、构建及仿真结果记录在固件旁的同名说明文件。
实物效果需烧录后按本文验收。
按仓库规范，Git 分支交付源码及说明；队友克隆后运行本文脚本生成 `.fs`。

## 本次验证摘要

- ModelSim 10.1d：`tb_joystick_control`、`tb_mcp3008_spi`、
  `tb_encoder_param_queue`、`tb_pitch_vibrato`、`tb_instrument_fsr_vibrato`
  五项均通过；整机测试明确设置 `ENABLE_JOYSTICK=1`。
- Gowin V1.9.12 完成综合、布局布线及位流生成，setup/hold 违规端点为 0/0。
- 音频 Fmax 13.464 MHz（要求 12.288 MHz），像素 Fmax 53.159 MHz
  （要求 33.333 MHz），LCD 输出时钟 Fmax 41.422 MHz（要求 33.333 MHz）。
- Logic 78173/138240，Register 25077/139095，BSRAM 28/340，DSP 38.5/298。
- 位流 37074089 字节，SHA256：
  `A4433F492F559387437CEE32F0CCD834429758B35E832F0C31CEC05D320BC96A`。
- 仍有 PR1014 输入参考时钟通用路由警告，最终受约束时序通过。
  实物摇杆及屏幕的验收待上板完成。

本机构建日志：`sim/joystick_bend_test_build/20261015_193631/gowin_build.log`。
仿真日志及校验清单：`sim/joystick_bend_test_build/sim_20261015_193707/verification.json`。
这些生成文件保留于本地；上述摘要随源码交付。

## 功能

- 钢琴、编钟两种音色，32 声部；不包含吉他。
- MCP3008 CH0：FSR 颤音，沿用零点 1、满量程 899、死区 8 的标定。
- MCP3008 CH1：摇杆 X，全局弯音约 -2～+2 个半音，四次平均及音高平滑。
- X 中心为 ADC 512，480～544 之间不弯音；没有自动居中校准。
- CH2：采集 Y；当前不改变声音。摇杆 SW 未实现。
- 保留原有键盘、RGB 显示、编码器及板载耳机音频输出。

屏幕 `ADC` / `VIB` 仍表示 **FSR 的 CH0**，不显示摇杆 X 数值。

## 接线

以下芯片脚号只适用于 MCP3008 PDIP-16 裸芯片，先辨认缺口与 1 脚方向。

| 摇杆端子 | 连接 |
| --- | --- |
| VCC / + | 3.3 V |
| GND | 与 MCP3008、FPGA 共地 |
| VRx | MCP3008 CH1，芯片 2 脚 |
| VRy | MCP3008 CH2，芯片 3 脚 |
| SW | 暂不连接 |

FSR 分压继续接 CH0（芯片 1 脚）。MCP3008 VDD（16 脚）及 VREF（15 脚）接
3.3 V；AGND（14 脚）及 DGND（9 脚）接地。两轴模拟电压送入 ADC。

| MCP3008 SPI 端子 | FPGA 排针 | FPGA 封装管脚 |
| --- | --- | --- |
| CS / SHDN，10 脚 | J13-24 | A18 |
| CLK，13 脚 | J13-25 | D15 |
| DIN，11 脚 | J13-26 | D14 |
| DOUT，12 脚 | J13-27 | D16 |

## 上板验收

1. 断电接好模块，摇杆回中；给板供电后烧录本次测试 `.fs`。
2. FSR 不施压，先选钢琴，只按住一个琴键。居中时应听到稳定的原音高。
3. 缓慢将 X 拨到一端，再拨到另一端。声音应连续升高/降低，端点约相差
   4 个半音；安装方向决定向左或向右哪边升高。
4. 松开摇杆让它回中，仍按住琴键，音高应回到原值。重复几次检查是否能恢复。
5. 保持 X 居中、按住琴键，再施压 FSR，应产生颤音；同时拨 X，应在颤音上
   叠加弯音。拨 Y 不应覆盖 FSR 的颤音深度。
6. 松开琴键，尾音结束后应停止。再按两键，X 应同时改变两音的音高。
7. 切换编钟，重复弯音及松键检查。记录有无杂音、卡音、回中偏音。

如 X 没有效果，测 VRx 对 GND：中心通常约 1.65 V，拨到两端应接近 0 V 与
3.3 V。若只有上下拨动有效，检查 VRx/VRy 是否接反。若回中偏音，提供实际
VRx 中心电压，以便调整 `CENTER_X`；当前固定死区不覆盖所有模块偏差。

## 重建

在仓库根目录执行：

```powershell
& 'E:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe' './tools/build_joystick_bend_test.tcl'
```

脚本创建 `project/instrument_24_rgb_joystick_bend_test_时间戳`，在 `generated`
下保存启用弯音的顶层副本。器件为 `GW5AST-LV138PG484AC1/I0`，版本 C。
标准顶层默认参数保持为 0；测试副本设为 1。工程目录保留于本地。

构建日志末尾 `JOYSTICK_TEST_BITSTREAM=` 给出 `.fs` 路径。交付前检查
最终时序、文件大小和复制前后的 SHA256，并通过现有摇杆/SPI/参数队列/
颤音/整机仿真。软件验证不代替实物上板验收。
