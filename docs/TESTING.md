# 测试与测量

## 文件校验

```sh
python -B tools/verify_release.py
```

检查发布文件SHA256、Gowin工程引用、头文件、ROM路径及文档链接。固件共一份，SHA256：

```text
2A1C5EA9A07E9421049F5E1623558A684046DF6744FAAC9D5258CDDCDEC18EF8
```

现有工具报告位于 `final/project/integrated_instrument_64/impl/pnr/`。本次整理仅执行文件校验，未重建工程或重新测量硬件。

## 仿真与软件测试

- `final/verification/tb_*.v`：扫描、消抖、波形与复音控制testbench。
- `final/project/integrated_instrument_64/`：工程内随附的模块测试与脚本。
- `companion/phone/app_test.cjs`、`protocol_test.cjs`：使用Node运行网页与协议测试。
- `final/k230/test_*.py`：K230控制逻辑测试。

各测试的时钟、依赖与编译选项见对应文件。历史测试结果不计作本次运行结果。

## 板上测量

| 项目 | 方法 |
| --- | --- |
| 采样率 | 示波器测LRCK完整周期，Fs=1/T；目标48kHz |
| 演奏延迟 | 同时观察第二有效触点闭合与DAC模拟起音，重复采集并记录范围 |
| 64复音 | TEST开启ALL，采集DAC模拟输出，再用GROUP与逐路MUTE对照频点 |
| 力度 | 同键快慢按，比较输出幅度、泛音和起音；逐键检查标定 |
| 曲目指引 | 验证自由/节奏模式、退出重进、下载第三槽及完成灯效 |
| 蓝牙回传 | 验证记录数量、断线重连与JSON/MIDI导出 |

64声部测试频率为 `(257+32×i)×Fs/16384`，i=0–63。保留固件哈希、实测Fs、仪器设置、原始采集与截图。赛题延迟指标需由实体触点至模拟输出的实测支持。

PC分析工具位于 `final/tools/`，依赖见 `final/requirements.txt`，可通过 `start_acceptance.cmd` 启动。

## 2026年11月1日测量资料整理

新增独立目录 [testing](../testing/README.md)，不覆盖旧PC工具或冻结工程。包括LRCK两次采集、DAC模拟输出ALL64／GROUP／部分MUTE、钢琴24键84次联合延迟及吉他和编钟抽样记录。数据来自团队提供的归档，未重新连接仪器。

钢琴84次条件性包络最大3.879094ms；该值依赖起点模型、经验余量及仪器假设，不是校准确认的严格物理上界。不要用旧单次3.72ms或屏幕ACTIVE数代替完整统计与模拟输出证据。
