# 成员 A 任务书 · 音频合成与音质优化

> 负责目录 `rtl/audio_core/`、`sim/audio_core_tb/`；独立工程 `audio_core_sim.gprj`；分支 `dev-audio`。
>
> 本文档由团队原始 Word 文件自动转换归档，内容未作修改。
> 权威的接口与平台信息以 `INTERFACE_FREEZE.md` 和 `PLATFORM_TANG_MEGA_138K.md` 为准。

---

成员 A 任务书 音频合成与音质优化
最新平衡方案 | 独立工程 audio_core_sim.gprj | 分支 dev-audio
阅读说明：本文件同时面向成员和 AI 助手。成员负责真实硬件判断、测量和最终决策；AI 负责按边界生成代码、testbench、分析和修改建议。任何跨目录或跨接口修改都必须先提出变更。
一 你的最终职责
你负责把标准演奏事件转换成逐采样数字音频，并对音高、包络、复音、音色、混音和资源进行闭环验证。你的工作重点是“声音如何生成、声音是否正确”，不负责 I2S 物理输出、传感器读取或整机顶层。
二 边界与合作
你负责
由其他成员负责
DDS/NCO、波表、FM/加法合成、声部管理、ADSR、混音、音色和音质验证
B：键盘、触摸、力度、编码器、OLED 页面和参数来源
输出标准 audio_core_valid/left/right 和状态信号
C：sample_tick、I2S、音效后端、管脚、Gowin 顶层和上板整合
定点格式、位宽、资源、时序和波形质量
C 负责最终全系统时序；你提供核心资源数据
三 独立目录与禁止修改
rtl/audio_core/
  note_to_fc.v phase_acc.v wavetable.v oscillator.v
  adsr.v voice_allocator.v voice.v mixer.v fm_operator.v audio_core.v
sim/audio_core_tb/
  audio_core_sim.gprj tb_audio_core.v
只修改 rtl/audio_core/ 和 sim/audio_core_tb/。
不要修改 synth_top.v、*.gprj（系统工程）、*.cst、*.sdc、rtl/input/、rtl/ui/ 和 rtl/system/。
若发现接口不够，先提交接口变更说明，不要直接侵入 B/C 目录。
四 固定接口
input  clk, rst_n, sample_tick
input  event_valid, event_type[1:0], note_id[6:0], velocity[7:0]
input  param_valid, param_id[3:0], param_value[15:0]
output audio_core_valid, audio_left signed[23:0], audio_right signed[23:0]
output active_voice_count[5:0], engine_ready, overload_flag
事件：EVENT_NOTE_ON、EVENT_NOTE_OFF、EVENT_PARAM_CHANGE。核心只在 sample_tick 或明确握手点更新音频状态；禁止依赖不受控的异步组合输入。
五 分阶段实施
A0 接口、定点和仿真骨架
建立 audio_core_sim.gprj 和 tb_audio_core。
确定采样率、相位累加器位宽、波表地址位宽、音频幅度格式、混音保护位和饱和策略。
用虚拟事件替代 B，testbench 必须能自动发送 NOTE_ON/OFF 和参数。
A1 单音实时合成
实现 note_to_fc、phase_acc、wavetable、oscillator。
至少支持正弦波和可变音高；提供固定测试音。
验证频率误差、相位连续性、复位静音和 sample_tick 对齐。
A2 基础赛题引擎
实现 4～8 个独立声部、声部分配、NOTE_ON/OFF。
每声部独立 ADSR，松键进入 Release，不得硬截断。
实现混音、总增益、限幅和 overload_flag。
输出 active_voice_count 供 C/B 显示和测试。
A3 冲奖音色与复音
扩展 16～32 复音或可按规则证明的独立振荡器。
增加第二音色；选择 FM 或加法合成并记录振荡器统计方式。
支持滑音、颤音等连续参数；提供多频测试模式。
A4 音质与资源闭环
检查音符切换爆音、包络边界、声部抢占和混音溢出。
输出频率/频谱/包络测试结果和 LUT/FF/BRAM/DSP/最高频率数据。
对每次位宽或架构优化说明音质、资源和时序影响。
六 AI 能直接完成什么
生成模块 RTL、testbench、定点计算和波形检查脚本。
根据错误日志定位状态机、位宽、符号扩展和握手问题。
根据资源报告给出并行/时分复用建议。
七 必须由人确认什么
听感、爆音、音色是否像目标乐器；AI 不能替代实际听音。
最终复音数、资源是否适合 Tang Mega 60K；必须看 Gowin 综合报告。
第二音色和音效的比赛展示效果；必须结合频谱和现场演示。
八 独立仿真步骤
新建 audio_core_sim.gprj，加入音频 RTL 和 tb_audio_core，设置 tb_audio_core 为仿真顶层。
testbench 依次发送单音、NOTE_OFF、四复音、八复音、参数变化和多频测试模式。
观察 audio_left/right、active_voice_count、engine_ready、overload_flag 和 ADSR 状态。
自动检查静音、频率范围、事件响应和释放时间；保存波形配置。
九 交付物和验收
阶段
交付与通过条件
A1
单音音高正确、输出连续、复位静音、testbench 可重复
A2
≥4 复音、独立 ADSR、无明显溢出、接口稳定
A3
第二音色、16/32 复音或等价振荡器证据、多频谱峰
A4
RTL 可综合、资源/时序数据完整、音质问题有结论
十 给 AI 的完整工作指令
你是本项目的 FPGA 数字音频 RTL 工程师。只在 rtl/audio_core/ 和 sim/audio_core_tb/ 工作。先说明采样率、时钟、定点格式、位宽和资源假设，再生成可综合 RTL 和独立 testbench。不得播放预录 PCM，不得修改系统顶层、I2S、输入或 OLED。每次输出都要包含：修改文件、接口变化、仿真检查、综合风险、需要人工测量的项目。
