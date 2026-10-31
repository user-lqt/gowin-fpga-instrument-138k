# 验证记录与验收边界

## 本次整理实际执行

只执行文件复制校验、Gowin文件清单依赖检查、头文件及ROM路径检查、源码与固件SHA256比对和文档链接检查。未运行综合、布局布线、烧录、示波器或手机实连，也未把历史日志当作本次重新测试。

最终文件来源及每个文件的SHA256在[发布清单](../release/manifest.json)。可运行 `python -B tools/verify_release.py` 重复检查；它不导入工程内构建工具，不启动Gowin。

## 已有资料分类

| 目录 | 含义 |
| --- | --- |
| `final/project/integrated_instrument_64/impl/pnr/` | 与用户指定固件同目录的原有PNR、引脚、资源及帧式HTML时序报告；保留原字节 |
| `final/reports/` | 原包历史报告、迁移审计，不自动认定对应最新21:35生成的FS |
| `final/verification/latency_determinism_001/` | 离线RTL时间观察记录，不是实体触点至模拟DAC实测 |
| `final/verification/warning_review_20261031/` | 历史警告检查及回归记录 |
| `final/verification/tb_*.v` | 扫描、消抖、波形、振荡器和复音控制测试源码 |
| `final/docs/simulation/` | 仿真图像，不是上板截图 |

原有PNR日志记录2026年10月31日21:36完成，并保留PR1014参考时钟路由警告。报告写的是该次工具结果，不能据此说全部硬件测试已通过。本次未重新构建，也不保证当前拷贝源码与已有FS存在可重现的完整构建输入证明；二者作为用户指定交付快照分别保留。

## 采样率与延迟

实际输出采样率应测PCM5102A的LRCK完整周期。目标约48kHz；BCK不是Fs，内部主时钟也不是Fs。硬件采样率与时间标定以现场记录为准。

延迟应说明起点（例如第二有效触点闭合）与终点（DAC模拟起音阈值），包含实际扫描、消抖、排队、合成、I2S与DAC。采集多次并报告最小/最大及测量条件。内部事件到数字样本或仿真闭合到事件的时长，不能替代该整机指标。

赛题基本指标≤10ms、拓展≤5ms属于验收目标；没有对应实测记录时不写成已达标。当前离线summary明确标记 `physical_closure_to_analog_DAC_simulated=false`。

## 64复音

1. TEST选ALL，确认真实声部数64，等待应用和稳定。
2. 从DAC模拟输出采集，观察64个目标频点。
3. 切GROUP，确认对应16个频点。
4. 逐路MUTE确认对应峰下降，再恢复ALL。
5. 保留实际固件哈希、Fs、采集带宽、分辨率、采样文件和截图。

目标频率为 `(257+32×i)×Fs/16384`，i=0至63；吞吐量为实际同时独立发声数×实际Fs。屏幕峰值、声部标签、左右声道、谐波和DSP个数不可重复计数。若实测Fs为48kHz，64×48000为3,072,000声部采样/秒，该数字不能替代频点独立性证据。

`final/tools/acceptance_gui.py`、`acceptance_scope.py`、`acceptance_reports.py` 为最终包原有PC采集分析工具，安装依赖见 `final/requirements.txt`。它们面向对应仪器/声卡与用户确认操作，不能理解为仓库打开后已自动完成测量。

## 配套网页

配套网页保留 `app_test.cjs` 与 `protocol_test.cjs`，可在Node环境运行。测试模拟GATT和协议，不代替手机、ESP、FPGA与灯带现场联动。仓库整理时仅报告实际运行结果，不混用此前分支的测试结论。
