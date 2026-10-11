# 成员 C 任务书 · 音频输出与 FPGA 系统平台

> 负责目录 `rtl/system/`、`rtl/common/`、`project/`、`constraint/`、`sim/system_tb/`；分支 `dev-system`。兼任集成责任人。
>
> 阶段0、1、2保留历史任务；阶段3、4以[当前详细任务书](finished_hardware/阶段三四成员任务书.md)为准。C3详见9.4，C4详见10.3和12.3；当前平台为Tang Mega 138K。总音量在A处理，C不重复施加同一增益。
> 权威的接口与平台信息以 `INTERFACE_FREEZE.md` 和 `PLATFORM_TANG_MEGA_138K.md` 为准。

---

成员 C 任务书 音频输出与 FPGA 系统平台
最新平衡方案 | 独立工程 audio_system_sim.gprj / synth_top.gprj | 分支 dev-system
阅读说明：本文件同时面向成员和 AI 助手。成员负责真实硬件判断、测量和最终决策；AI 负责按边界生成代码、testbench、分析和修改建议。任何跨目录或跨接口修改都必须先提出变更。
一 你的最终职责
你负责把 A 的原始采样变成稳定的 I2S 音频并完成 FPGA 平台、音效后端、顶层工程、约束和系统级验证。你的工作重点是“系统如何稳定输出并通过比赛现场验证”，不重写 A 的振荡器，也不重写 B 的传感器逻辑。
二 边界与合作
你负责
由其他成员负责
时钟、复位、sample_tick、采样管线、I2S、PCM5102A、音量、音效、LED、调试、顶层、约束和整机验证
A：音频核心内部合成、ADSR、声部和音色
把 B 的事件接入 A，把 A 的 sample 接到后端和 DAC
B：输入驱动、参数管理、OLED 页面内容
系统级延迟、资源、时序、稳定性和硬件安全
A/B 提供各自模块的独立证据和接口稳定性
三 独立目录与禁止修改
rtl/system/
  clock_gen.v reset_ctrl.v sample_scheduler.v audio_pipeline.v
  i2s_tx.v delay_effect.v reverb_effect.v chorus_effect.v
  effect_mixer.v led_status.v debug_uart.v performance_monitor.v
rtl/common/ event_defs.vh status_defs.vh reset_sync.v
project/ synth_top.v synth_top.gprj
constraint/ tang_mega.cst tang_mega.sdc
sim/system_tb/ audio_system_sim.gprj tb_system.v
C 独占维护 synth_top.v、系统 *.gprj、.cst、.sdc 和 rtl/system/。
不要修改 rtl/audio_core/ 和 rtl/input/ 内部实现；需要改接口时提出兼容方案。
C 维护 common 接口文件，但任何事件字段变更要通知 A/B。
四 固定接口
input event_valid, event_type, note_id, velocity, param_id, param_value
input audio_core_valid, audio_core_left[23:0], audio_core_right[23:0]
input active_voice_count[5:0], engine_ready, overload_flag
output i2s_bck, i2s_lrck, i2s_data
output system_ready, audio_locked, i2s_active, system_error
五 分阶段实施
C0 平台、接口和约束
建立 Tang Mega 60K Gowin 工程、器件型号、时钟/复位框架和独立 system 仿真。
确认板卡版本、时钟源、可用 GPIO、I2S/OLED/LED 管脚；将实际依据写入约束注释。
固定 event_defs.vh、status_defs.vh、sample_tick 和 reset 行为。
C1 独立 I2S 输出
用固定正弦或 ROM 样本替代 A，先验证 sample_scheduler 和 i2s_tx。
实现 48 kHz LRCK、BCK、左右声道、位宽和对齐策略。
接 PCM5102A，使用逻辑分析仪验证 LRCK/BCK/DATA；记录实测结果。
C2 音频后端管线
接入 A 的 audio_core_valid/left/right，处理 sample 握手、总音量、静音、淡入淡出和峰值。
实现削波/溢出标志和基础错误恢复。
测量输入事件到 I2S 首个有效样本的端到端延迟。
C3 音效与板级状态
集成32复音、三种音色、24键和EC11_A；完成I2S/DAC、延迟效果旁路、RGB波形/状态和性能验证。
详见当前详细任务书9.4；阶段三一次验收，不接入EC11_B、ADC或连续表情。
C4 顶层与比赛验证
集成EC11_B、MCP3008、FSR、摇杆、滑音/弯音/颤音和LED指引，完成最终约束、线束、性能与安全验收。
详见当前详细任务书10.3和12.3；所有Gowin综合、时序、上板与延迟实测由C负责。
六 AI 能直接完成什么
生成 I2S、采样调度、延迟线、简单 FIR/IIR、峰值监视器、LED 和 debug UART 模块。
根据仿真波形、综合报告和错误日志给出系统级排错步骤。
生成顶层连接模板，但不能替代实际管脚确认。
七 必须由人确认什么
Tang Mega 60K 当前板卡的真实管脚、时钟和底板连接。
I2S 位对齐、LRCK/BCK 实测频率、PCM5102A 是否实际发声。
Gowin 综合/布局布线、时序收敛、资源余量和长期稳定性。
功放 BTL 输出不可接地、功放供电和示波器接地安全。
八 独立仿真与 Gowin 流程
audio_system_sim 用固定样本发生器验证 sample_scheduler、audio_pipeline、effect_mixer 和 i2s_tx。
先用 stub 代替 A/B，再将真实模块加入 system_tb；接口问题定位在边界，不复制模块内部代码。
功能仿真加入 RTL、testbench 和器件对应 prim_sim.v（若使用原语）。
设置 top module 为 synth_top，运行综合、Place &amp; Route、时序检查，再上板。
保留实测逻辑分析仪波形和延迟结果；不要把 impl 缓存和临时文件提交。
九 交付物与验收
阶段
交付与通过条件
C1
固定样本 I2S 稳定；LRCK/BCK/DATA 实测格式正确
C2
A 采样可接入；总音量/削波/峰值和延迟可测
C3
32复音、三音色、24键、EC11_A及音效/显示整机验证；资源、时序和基础延迟证据齐全
C4
传感器/表情/LED整机回归，最终资源时序、基础/拓展延迟、连续运行和交付资料齐全
十 给 AI 的完整工作指令
你是 Gowin FPGA 系统和数字音频后端工程师。只修改 rtl/system/、rtl/common/、project/、constraint/ 和 sim/system_tb/。先说明板卡、时钟、采样率、I2S 对齐、资源和延迟假设，再生成 RTL/testbench/约束建议。不得重写 A 的合成器或 B 的输入驱动。每次输出必须区分仿真可验证项、需要 Gowin 综合确认项和必须上板测量项。
