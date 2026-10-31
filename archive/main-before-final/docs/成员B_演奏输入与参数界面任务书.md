# 成员 B 任务书 · 演奏输入与参数界面

> 负责目录 `rtl/input/`、`rtl/ui/`、`sim/input_ui_tb/`；独立工程 `input_ui_sim.gprj`；分支 `dev-input`。
>
> 本文档由团队原始 Word 文件自动转换归档，内容未作修改。
> 权威的接口与平台信息以 `INTERFACE_FREEZE.md` 和 `PLATFORM_TANG_MEGA_138K.md` 为准。

---

成员 B 任务书 演奏输入与参数界面
最新平衡方案 | 独立工程 input_ui_sim.gprj | 分支 dev-input
阅读说明：本文件同时面向成员和 AI 助手。成员负责真实硬件判断、测量和最终决策；AI 负责按边界生成代码、testbench、分析和修改建议。任何跨目录或跨接口修改都必须先提出变更。
一 你的最终职责
你负责把人的演奏动作变成可靠事件和连续参数，并负责参数管理与 OLED 用户界面内容。你的工作重点是“用户如何演奏、如何改变参数、如何看到状态”，不负责音频算法和 I2S。
二 边界与合作
你负责
由其他成员负责
矩阵键盘、编码器、触摸、力度、距离、滤波、校准、事件协议、参数管理、OLED 页面内容
A：振荡器、声部、ADSR、混音和音色内部实现
UI 页面、显示字段、菜单状态、用户参数变化
C：OLED 管脚时序接入、系统时钟、I2S、音效、最终顶层
输入延迟、误触发、电平安全和传感器稳定性测试
C 负责整机延迟，但你提供输入侧延迟数据
三 独立目录与禁止修改
rtl/input/
  matrix_scan.v key_debounce.v key_map.v encoder.v
  ultrasonic_ctrl.v mpr121_ctrl.v pressure_adc.v
  input_filter.v expression_mapper.v input_top.v
rtl/ui/
  parameter_manager.v ui_state.v oled_page.v oled_content.v
sim/input_ui_tb/
  input_ui_sim.gprj tb_input.v tb_encoder.v tb_sensor.v
只修改 rtl/input/、rtl/ui/ 和 sim/input_ui_tb/。
不要修改 rtl/audio_core/、rtl/system/、synth_top.v、*.cst、*.sdc。
OLED 驱动的低级 I2C 时序若由 C 维护，你提供页面数据/状态接口，不复制另一份驱动。
四 固定接口
output event_valid, event_type[1:0], note_id[6:0], velocity[7:0]
output param_valid, param_id[3:0], param_value[15:0]
output key_state[15:0], sensor_value[15:0], input_ready
output ui_page[3:0], ui_param_value[15:0], ui_dirty
事件：EVENT_NOTE_ON、EVENT_NOTE_OFF、EVENT_PARAM_CHANGE。参数：PARAM_VOLUME、PARAM_INSTRUMENT、PARAM_PITCH_BEND、PARAM_MODULATION、PARAM_FILTER、PARAM_EFFECT_MIX。输出必须经过限幅、滤波和校准。
五 分阶段实施
B0 接口和虚拟输入
建立 input_ui_sim.gprj、tb_input、tb_encoder、tb_sensor。
定义按键事件脉宽、重复规则、参数范围、UI 页面状态和复位默认值。
所有模块必须能在没有真实硬件时用 testbench 产生可检查输出。
B1 矩阵键盘
实现扫描节拍、行列控制、消抖、键值映射和 NOTE_ON/OFF。
保证一次按下只触发一次，一次松开只触发一次。
支持基础多键；记录廉价薄膜键盘鬼键限制，不在 RTL 中假装解决不存在的硬件问题。
B2 第二演奏维度与参数管理
优先完成 EC11 编码器正交解码、去抖、正反转和步进累计。
将编码器映射到音量、音色、滑音或效果混合，并输出 PARAM_CHANGE。
可选 HC-SR04：处理触发、回波计时和超时；只接收已经分压到 3.3 V 的逻辑。
建立 parameter_manager，统一范围、默认值、步长和页面显示。
B3 三维表情
实现 MPR121 I2C 状态读取、FSR402/MCP3008 SPI 采样或等价方案。
形成音符、力度、连续表情三个维度。
实现均值/中值/一阶 IIR、迟滞、校准、异常值和断线默认值。
B4 OLED 用户界面
设计页面：音色、音量、活跃声部、效果混合、传感器状态、校准和错误提示。
把页面内容与低级 OLED I2C 发送解耦；输出 ui_page/ui_param_value/ui_dirty。
用虚拟状态测试页面切换、数值更新和错误显示。
六 AI 能直接完成什么
生成扫描器、消抖、编码器、I2C/SPI 状态机和输入 testbench。
生成参数管理器、页面状态机、数值格式化和 UI 测试激励。
根据仿真波形分析重复事件、边界、计数和滤波问题。
七 必须由人确认什么
真实传感器供电、电平、上拉、接线和模块版本。
触摸误触发、FSR 个体差异、超声波异常和矩阵鬼键。
OLED 实际可读性、交互手感和演示现场的参数默认值。
八 硬件安全
HC-SR04 ECHO 不得直接进入 FPGA，必须外部电阻分压到约 3.3 V。
MPR121/OLED 等模块确认 3.3 V 供电和上拉；未知 5 V 模块不得直连。
记录每个接口的 VCC、GND、SCL/SDA、SPI、IRQ、GPIO 方向。
九 独立仿真与验收
tb_input 模拟抖动、单键、多键、保持和松开，检查事件唯一性。
tb_encoder 模拟正交相位序列，检查方向、步进、限幅。
tb_sensor 模拟缓慢变化、噪声、突变、越界和断线，检查滤波/校准。
tb_ui 模拟音色/音量/效果变化，检查 ui_dirty 和页面内容。
阶段
交付与通过条件
B1
键盘事件正确、无重复、映射稳定
B2
第二维控制可稳定输出参数；参数范围和页面显示一致
B3
第三维表情、滤波、校准和异常默认值有效
B4
UI 页面可用；真实硬件连续运行；输入延迟和误触发有记录
十 给 AI 的完整工作指令
你是本项目的 FPGA 输入、传感器和控制界面工程师。只在 rtl/input/、rtl/ui/ 和 sim/input_ui_tb/ 工作。先给出电平、采样周期、去抖、滤波、参数范围和延迟假设，再生成可综合 RTL、testbench 和接口说明。不得生成音频算法、I2S 或系统顶层。每次输出都要区分仿真可证明项与必须上板测量项。
