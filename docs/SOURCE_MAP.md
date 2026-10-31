# 源码 成员与历史资料导航

## 当前完整工程

最终工程以 `final/project/integrated_instrument_64/source/` 为统一源码树，不从三条开发分支再次拼接替换模块。用户交付的最终快照优先于历史任务书和分支版本。

| 功能 | 当前目录或文件 | 维护来源 |
| --- | --- | --- |
| 三音色 声部 ADSR 混音 力度音质 | `rtl/audio_core/` | 成员A音频基线与后续集成 |
| 双触点 扫描 编码器 事件映射 | `rtl/input/` | 成员B输入及交互，部分系统集成 |
| RGB界面 FFT 波形 XY | `rtl/ui/` | 界面与可视化集成 |
| PLL 采样 I2S 系统状态 | `rtl/system/` | 成员C平台与音频输出 |
| FSR 摇杆 MCP3008 K230接收 | `rtl/input/` 及最终K230程序 | 成员C扩展与后续集成 |
| 事件协议 复位公共模块 | `rtl/common/` | 团队公共接口 |
| 顶层64声部参数和模块连接 | `source/project/` | 最终整机集成 |
| 实际球位与时序约束 | `source/constraint/` | 最终工程原CST及SDC |
| FFT第三方基础实现 | `source/vendor/r22sdf/` | 原作者许可，保留声明 |

上表为职责导航，不为逐行代码重新认定作者。原提交作者和历史在Git中保留。

## 原始任务书与方案

三位成员的任务书、项目总计划与采购阶段表保留在[主干归档docs](../archive/main-before-final/docs/)。它们说明开发过程，包含阶段目标、未采购方案和旧接口，不作为当前已实现功能或最终物料清单。

- [总计划书](../archive/main-before-final/docs/高云FPGA电子乐器项目总计划书_最终版.md)
- [成员A任务书](../archive/main-before-final/docs/成员A_音频合成与音质优化任务书.md)
- [成员B任务书](../archive/main-before-final/docs/成员B_演奏输入与参数界面任务书.md)
- [成员C任务书](../archive/main-before-final/docs/成员C_音频输出与FPGA系统平台任务书.md)
- [阶段采购清单](../archive/main-before-final/docs/高云FPGA电子乐器分阶段硬件采购清单.md)

当前方案与实物连接从[系统架构](ARCHITECTURE.md)和[硬件说明](HARDWARE.md)开始阅读，不从旧采购表推断当前使用OLED、MPR121或板载DAC。

## 历史分支

`dev-audio`、`dev-input`、`dev-system` 保留三个成员的开发基线；`codex/integrated-instrument`、`fix/b-integrated-20261016`、`integration/*` 和其他功能分支保留集成过程。本次不删除分支、不重写提交，不通过merge将旧逻辑覆盖最终工程。

各分支整理时的精确提交号记录在[发布清单](../release/manifest.json)的 `remote_branch_snapshot`。部分有参考价值的硬件/算法说明原文提取到[成员历史说明](../archive/member-notes/)，其来源路径与提交号也在清单中。

需要追溯时可执行：

```powershell
git log --all --oneline --decorate
git show origin/dev-audio:rtl/audio_core/audio_core.v
git show origin/dev-system:docs/JOYSTICK_MCP3008_RTL.md
```

旧分支中32声部、早期管脚、旧NOTE编码、OLED或板载音频输出等描述均为当时背景，不能直接套入最终工程。
