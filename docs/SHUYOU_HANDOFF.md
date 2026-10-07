# shuyou 双 EC11 工程交接（2026-10-04）

> 历史交付说明：对应 `archive-dual-ec11` 标签。当前唯一整机入口为
> `integration/c-stage3`，以 [当前状态与任务](CURRENT_STATUS.md) 为准。
> A 已在 `dev-audio` 的 `6035c11` 上传 32 声部、钢琴/吉他/编钟；C 待集成。

这是成员 B 当前交付的完整工程。后续顺序明确为：**成员 A 完成并上传
EC11_A 三个音色、EC11_B 滑音处理，最后由成员 C 合并与整机验收**。
本说明优先于旧快照说明；旧文件记录历史版本，不代表当前功能全部完成。

## 当前工程入口

- Gowin V1.9.12，Tang Mega 138K / 31005，GW5AST-LV138PG484AC1/I0，版本 C。
- IDE 工程：`project/instrument_24_rgb_dual_ec11/instrument_24_rgb_dual_ec11.gprj`。
- 顶层：`project/instrument_24_rgb_top.v`。
- 约束：`constraint/instrument_24_rgb_mega138k.cst` / 同名 `.sdc`。
- 烧录文件：`project/instrument_24_rgb_dual_ec11/impl/pnr/instrument_24_rgb_dual_ec11.fs`。
- 构建入口：`tools/build_dual_ec11.tcl`。
- 自动回归：`tools/verify_strike_expression.ps1`（XSim 路径按本机安装调整）。

在仓库根目录执行：

```powershell
& 'E:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe' tools/build_dual_ec11.tcl
powershell -ExecutionPolicy Bypass -File tools/verify_strike_expression.ps1
```

烧录文件 SHA256：
`10155BE6384F24ADAEE1C804EE3C7A75409ADD699C2F0542274434956DF7F035`。

## 成员 B 已完成

| 控制 | 操作 | 公共参数 |
| --- | --- | --- |
| EC11_A | 旋转始终调音量，0–127，每格4，默认64 | PARAM_VOLUME=0，映射0–65535 |
| EC11_A | 短按循环音色编号0→1→2→0 | PARAM_INSTRUMENT=1，值0/1/2 |
| EC11_B | 短按切换 GLIDE / FX，旋转修改选中值，分别保值 | 下列两项 |
| GLIDE | 0–127，每格4，默认0 | PARAM_GLIDE=6，映射0–65535 |
| FX | 0–127，每格4，默认0 | PARAM_EFFECT_MIX=5，映射0–65535 |

连续和同拍更新经8条参数队列送到音频核心，溢出标志 `control_overflow`
使状态灯常亮，复位清除。两旋钮和音频均用同一音频时钟域。
RGB 显示音量、音色位置、琴键和底部 GLIDE/FX 菜单。

EC11_A：A→J13-17/A21，B→18/B21，D→19/B18。
EC11_B：A→J13-21/C17，B→22/D17，D→23/E19。
两只 C/E 共地；每个 A/B/D 独立4.7kΩ上拉至3.3V，不能接5V。
详见 `EC11_B_WIRING.md`、`EC11_FORMAL_CONTROLS.md`、`KEYBOARD_24_PINOUT.md`。

## 成员 A 下一步：完成音频并上传

1. **EC11_A 三个音色**：按团队原计划完成正式的三种音色，并与输入编号
   0/1/2 对齐，上传音频源码及测试证据。当前快照已有正弦/三角/锯齿基础
   波形，不等于团队正式三音色与音质验收已经完成。音色由当前声部起音时
   锁存；如需改变切换行为，应在交接说明中写清楚。
2. **EC11_B 滑音**：在音频核心接收 PARAM_GLIDE=6，实现真正的滑音处理，
   上传源码与仿真证据。0须关闭滑音；0–65535如何映射毫秒、复音场景如何
   选择起止音高，由 A/C 明确说明。B 的输出值当前不是毫秒。
3. **效果接口**：菜单已经发送 PARAM_EFFECT_MIX=5，但当前音频核心不处理
   此ID。效果算法和干湿比接入按原计划完成；未实现期间须保持明确的待完成
   状态，不把菜单变化当成声音效果通过。

当前本地音频核心只实际处理音量和音色，因此 EC11_B 参数可调、可发送，
**本历史固件的滑音与效果声音尚未实现**。该整机仍为4复音；A 的32复音
源码已上传，待 C 集成和整机验收。A 新源码的表情开关默认关闭，其独立仿真
也不能代替当前整机验收。
该历史固件保留双触点时间差约1秒以上降一八度、约40%增益的行为；最终力度
目标是基频不变、音量及泛音/音色随力度变化，由 B 开发、A 配合迁移及回归。

## 最后由成员 C 合并

成员 A 上传完成后，由 C 合并本分支的输入/UI/约束/队列与 A 的音频实现。
不要用旧 PMOD 接线替换已验证 J13 分配，也不要覆盖旧音频代码来丢失 A
的后续实现；以最终接口一致、可构建的集成结果为准。

C 应复跑仿真与高云构建，并上板验收两旋钮同时操作、三音色、滑音、
NOTE_OFF释放、参数队列无溢出、琴键、RGB及音频输出。阶段标签与正式
验收由 C 完成，本分支不自动合入 main。

## 当前证据与范围

用户反馈本次双编码器版本已好；仍需 A/C 完成声音功能后再次整机验收。
8项自动回归通过：RGB光栅、双生产者队列、双旋钮菜单、EC11_A正式控制、
旧诊断兼容、双触点键盘、击键表情及整机输入到DAC。
最新高云报告在当前SDC下setup/hold违例为0；既有参考时钟布线与音频位宽
警告仍在，不宣称无警告。中间编译缓存、外部临时资料不随工程上传。
