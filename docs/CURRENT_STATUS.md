# 当前状态与任务

核对日期：2026-10-07。本页区分远程源码交付、现有整机固件及历史上板记录。

## 当前双音色与 FSR 颤音实现

当前集成分支已接入 A 的 `6035c11` 音频 RTL，启用32声部与音高表情。
按用户要求，本次整机排除吉他硬件，保留钢琴与编钟；编码器音色槽位0/1映射
到音频ID 0/2，吉他源码保留。双音色工程入口为 `tools/build_fsr_two_timbres.tcl`。
共享 MCP3008 CH0 经滤波、压力映射和四源参数队列控制约5 Hz、最大±50音分
的全局颤音；用户已确认 CH1 摇杆 X 接好，同时保留弯音，CH2 不覆盖颤音深度。
新增 DAC 帧缓存，保证左右声道使用同一帧 PCM；32声部混音预留1/32增益余量。

音频32声部/三音色表情回归，以及模拟 SPI 到 FSR、持续音符、DAC 的整链路
仿真已通过。前三音色版本布线失败（6900条未布通连线），未生成固件；该轮
已停止。用户随后授权排除吉他重新布线，双音色32声部与编码器/FSR整链路
回归已通过，双音色布局布线成功。最终逻辑占用56%、寄存器18%、BSRAM 9%、
DSP 12%，建立和保持时间违规均为0；新烧录文件为
`project/instrument_24_rgb_fsr_two_timbres/impl/pnr/instrument_24_rgb_fsr_two_timbres.fs`，
上板听感尚待确认。源码、工程、构建脚本及验证摘要统一由
`integration/c-stage3` 交付，生成的 `.fs` 保留在本地。
详见 [FSR颤音接入与测试](FSR_VIBRATO_INTEGRATION.md)。

## 正式入口

| 入口 | 责任与状态 |
| --- | --- |
| `dev-audio` | A 音频开发；`6035c11` 已交付32声部、钢琴/吉他/编钟 |
| `dev-input` | B 输入、控制、显示及力度开发；保留独有历史提交，后续按模块交付 |
| `dev-system` | C 系统平台开发；从当前整机入口快进恢复 |
| `integration/c-stage3` | 唯一整机集成、构建及联合验收入口 |
| `main` | 已发布版本；仅接受整机验收通过的 PR |

整机本地目录：`E:\GowinProjects\synth_top_integration_latest`。
C 日常开发目录：`E:\GowinProjects\synth_top_system`。
A 最新源码参考目录：`E:\GowinProjects\synth_top_audio_latest`。
本地分支名及历史目录详见 [分支整理记录](GITHUB_BRANCH_CLEANUP.md)。

## 已有成果与限制

当前整机工程为
`project/instrument_24_rgb_fsr_two_timbres/instrument_24_rgb_fsr_two_timbres.gprj`，
包含24键、RGB、双EC11、MCP3008轮询、32声部与FSR颤音。
使用 `tools/build_fsr_two_timbres.tcl` 构建以应用完整配置。
原 `project/instrument_24_rgb_top/impl/pnr/instrument_24_rgb_top.fs` 保留，
它仍使用4声部音频核心；工程源码更新不改变已有烧录文件。

A 在 `dev-audio` 的 `6035c11` 已交付32声部音频源码，音色0/1/2分别为
钢琴、吉他、编钟。音频采样预算为每样本256个12.288 MHz时钟，32声部
默认PCM有效延迟为109个时钟；这不是输入到DAC的实测总延迟。
集成时需添加 `rtl/audio_core/` 的全部 `.v` 文件，包括共享运算与RAM模块。

A 新源码的 `ENABLE_EXPRESSION` 默认为0；当前整机已打开并验证弯音与颤音
参数通路，实体听感尚未验收。64声部候选与独立PCM验证在
交接资料中仅描述为本地成果，未上传，不据此宣称整机升级完成。

旧整机的慢击键降八度仅作为历史行为保留。最终力度要求是同一音符的
基频不变，音量、泛音比例和音色随力度改变。B负责检测与声音力度处理，
A配合迁移到64声部候选及回归，C负责工程集成和上板确认。

原整机固件只能采样和输出摇杆参数。当前源码已完成共享ADC CH0压力滤波
与映射，接入音频颤音，并验证摇杆X与FSR共存；烧录验收使用新构建结果。

## 后续交付

1. C完成双音色32声部与FSR固件的音色/表情上板确认；布局布线和资源时序检查已通过，109周期PCM到DAC的帧缓存已接入。
2. B在正式入口交付力度检测及钢琴/编钟的软/中/重响应；A配合回归，确保基频与映射保持一致。
3. B/C复核B先于A、同帧闭合、抖动、释放及重触发，再决定如何合入 `fix/ab-order`；不直接照搬旧版补丁。
4. C完成FSR ADC实物标定与颤音听感确认；源码已规定FSR独占 `PARAM_MODULATION`，摇杆X负责弯音。
5. 整机通过验收后由集成分支向 `main` 提发布PR；阶段标签只代表已实际完成的验收。

历史文档保留原文件；旧分支名字、旧功能描述和旧测试结论应按其记录的提交
阅读。历史版本定位及烧录文件SHA256见 [分支整理记录](GITHUB_BRANCH_CLEANUP.md)。
