# GitHub 分支整理记录

执行日期：2026-10-07。依据用户确认的分支整理方案执行；保留所有本地文件、
工作目录、未提交内容及本地历史分支。远程历史入口由标签保留。

## 正式结构与路径

| 分支 | 用途 | 本地目录 |
| --- | --- | --- |
| `dev-audio` | A音频开发；当前交付 `6035c11` | `E:\GowinProjects\synth_top_audio_latest`，本地参考分支为 `review/audio-stage3` |
| `dev-input` | B输入/显示/力度开发；保留 `14b7f09` 和独有历史测试 | B后续交付按模块评审，不覆盖当前整机 |
| `dev-system` | C系统开发；快进至此次整理后的整机起点 | `E:\GowinProjects\synth_top_system` |
| `integration/c-stage3` | 唯一整机集成与验收入口 | `E:\GowinProjects\synth_top_integration_latest` |
| `main` | 发布已验收版本；本轮保留 `1b47f25` | 通过发布PR更新 |

远程同时保留 `feat/fsr-mcp3008` 与 `fix/ab-order`，直至完成兼容集成及回归。
旧 `feature/c-24-key-rgb`、`shuyou`、`joystick` 不再作为远程交付入口。
其源码提交均为 `integration/c-stage3` 的祖先，删除分支名不删除这些提交。
本地旧分支仍在，直接推送旧名字可能重建远程分支；后续请向正式入口交付。

## 历史标签与烧录身份

| 标签 | 提交 | 内容和验收范围 |
| --- | --- | --- |
| `archive-keyboard24-rgb` | `071d8f7` | 24键/RGB历史源码；提交不包含烧录文件，不以早期固件哈希推定其身份 |
| `board-j13-ec11` | `3f315f2` | 已记录用户上板可用的单EC11版本；4声部、24键、RGB；不是阶段三验收标签 |
| `archive-dual-ec11` | `e10f847` | 双EC11菜单及历史交付；4声部，滑音/音效声音未完成 |
| `archive-joystick-adc` | `2b59eef` | ADC/摇杆采样交付；4声部，弯音/调制尚未产生声音 |

从所列Git提交中的原始字节重新计算SHA256，得到：

| 标签 | 烧录文件 | SHA256 |
| --- | --- | --- |
| `board-j13-ec11` | `project/instrument_24_rgb_ec11_j13/impl/pnr/instrument_24_rgb_ec11_j13.fs` | `7936109362849036CB199C882D98F803A0F32F516ABF34332223A38CD154C3B5` |
| `archive-dual-ec11` | `project/instrument_24_rgb_dual_ec11/impl/pnr/instrument_24_rgb_dual_ec11.fs` | `10155BE6384F24ADAEE1C804EE3C7A75409ADD699C2F0542274434956DF7F035` |
| `archive-joystick-adc` | `project/instrument_24_rgb_top/impl/pnr/instrument_24_rgb_top.fs` | `827C381ADD8906CDDFBB2351003EAB22E9276B17839EF052233DA17866B5CD30` |

各版本构建入口分别为 `tools/build_ec11_j13.tcl`、`tools/build_dual_ec11.tcl`
和 `tools/build_instrument_24_rgb.tcl`，工具为Gowin V1.9.12。
在独立目录检出对应标签后，从仓库根目录调用：

```powershell
& 'E:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe' tools/build_ec11_j13.tcl
```

其他版本换成表中对应脚本。重新构建的文件不能仅凭文件名认定与历史产物
完全相同，应重新记录哈希、综合与时序。此次整理不运行构建，不覆盖任何固件。

## 保留分支的代码评阅

`feat/fsr-mcp3008` 有三个集成分支未包含的提交：`b5bcef7`、`9175643`、
`508480c`，分别实现采样/滤波/映射、初始校准和实测分压估值。
它与整机都定义 `mcp3008_spi`，但FSR版使用 `miso/sclk/mosi/cs_n/data`，
整机版使用 `adc_miso/adc_sclk/adc_mosi/adc_cs_n/adc_data`，直接合并会造成
端口不兼容。整机已由 `mcp3008_sampler` 轮询CH0/CH1/CH2，应保留这一个SPI
主机，在CH0样本有效时复用压力滤波和映射，避免两个SPI主机同时驱动引脚。
FSR默认570/945/死区8及故障窗口需保留，最终以实物校准为准。
FSR与摇杆Y轴目前都面向 `PARAM_MODULATION=3`，集成前还需明确选择或合成规则。
本轮不合入RTL，待兼容改造和回归后才能清理该分支。

`fix/ab-order` 有一个独有提交 `4e708a0`。补丁要求B的消抖上升沿触发，
用于禁止B先闭合、A后闭合产生NOTE_ON。现行代码已重写行程捕获，判据为
`a_next && b_next && strike_measured`，没有等价的顺序限制：B保持闭合后A
闭合仍会记录同帧测量并触发。不能将其视为已修复，也不能盲目照搬旧上升沿
条件，否则可能漏掉同帧闭合的延后确认。保留分支；后续必须同时验证A→B、
同帧闭合、B→A、触点抖动、释放与再按。本轮结论来自代码评阅，不新增硬件结论。

`dev-input` 的四个独有历史提交包含独立输入工程与测试。当前整机已移植部分
输入/RGB功能，但不是提交历史合并；保留分支及B的测试，后续采用模块评审。
`dev-audio` 的独有音频成果也不在现有整机固件内，保持正式开发入口，待C集成。

## 核对及执行边界

已查询GitHub草稿PR、评阅记录、Actions工作流及本机自动化中的旧入口引用。
旧键盘草稿PR #3无评论、无评阅；由当前集成分支的新草稿接替后关闭，保留
全部历史。B的PR #1继续保留。当前仓库未配置Actions工作流，本机自动化未
发现这三个旧分支名引用；无法据此判断队友电脑上的工作状态。

`dev-system` 原来停在 `73b4f39`，是当前整机提交的祖先，本次以普通快进
恢复开发入口。新建独立C目录，原 `synth_top` 的99项未提交状态及其他旧工作
副本全部保留。本轮没有合入A/B的新RTL、没有将代码发布到 `main`，也没有
把4声部固件改称32声部固件。
