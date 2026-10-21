# 滑音交互语义

## 触发规则

`GLIDE` 打开且时间不为零时：

1. 全部琴键松开后按下第一个键，直接输出目标音高。
2. 保持一个或多个琴键按住，再按下新键，才启动从起点到新目标的滑音。
3. 起点选择仍处于 `key_down` 的最近一次按键；释放尾音（`voice_active` 仍为 1）不能作为起点。
4. 滑音途中再次按键，从起点声部当前的未调制音高继续计算，避免跳回旧目标音。
5. 松开当前最近键后，如果仍有其他键按住，下一次新键从剩余的最近按键开始；全部松开后重新按键直接起音。

`GLIDE=0` 保持原来的直接起音和复音行为。弯音与颤音仍在音高查表前叠加，
不改变滑音的起点选择。

## 屏幕显示

普通页面右侧滑音行显示 `GLIDE ON  300MS` 或 `GLIDE OFF 300MS`。
关闭时仍显示旋钮保留的时间预设；只有 ON 状态且新键与已按住的键重叠时才触发滑音。
录音状态与计数单独放在下一行，例如 `REC ON  024`，不再覆盖滑音行。
分析页和 TEST 页按各自布局显示，不叠加普通页面的滑音或录音文字。

## 实现位置

- `rtl/audio_core/voice_allocator.v` 的 `key_down` 是物理按键保持状态，释放尾音不置位。
- `rtl/audio_core/pitch_expression.v` 保存声部最近按键顺序，并以比较树选出最近仍按住的声部。
- `rtl/audio_core/audio_core.v` 将 `key_down` 连接到音高表达模块。

## 验证

```powershell
powershell -ExecutionPolicy Bypass -File tools/verify_legato.ps1
```

该回归包括首键直达、分离按键不滑、重叠按键上下行滑音、滑音链、释放尾音排除、
最近按键回退、同槽重触发、旁路，以及 32 声部整机事件 FIFO 和 PCM 节拍。

2026-10-21 实跑结果：ModelSim 10.1d 的 `tb_glide`、`tb_legato_core`、
`tb_controls_display` 均 PASS，整机顶层（PLL 仿真桩）展开通过。
屏幕修复后补跑 `tb_merged_dashboard` 和 `tb_test_dashboard`，连同上述三项回归全部 PASS；
检查了滑音与录音开关组合、全部 26 档时间预设、关闭后保留时间，以及普通页/分析页/TEST 页隔离。
`tb_glide` 另在 Icarus 13.0 通过。Icarus 13.0 对现有 `oscillator.v`
的 `multiply_product` 前向引用报错，整机验证因此使用 ModelSim，未为绕过该错误改动振荡器。

## 工程与固件

工程入口仍为 `project/instrument_fixed_top/instrument_fixed_top.gprj`，顶层为
`instrument_24_rgb_top`。本次修改源码和回归，尚未综合、布局布线或生成新固件；
已有 `prebuilt/instrument_fixed_top.fs` 是 10 月 18 日版本，不含本次滑音调整。
