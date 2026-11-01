# 电子乐器测试软件与测量结果

## 启动

在Windows中安装Python（含Tkinter），运行 `python -m pip install -r requirements.txt`，双击 `start_instrument_acceptance.cmd`。程序不在启动时自动连接仪器。

软件提供复音、按键延迟、LRCK采样率、评分证据四页。操作步骤见 [README_ACCEPTANCE.md](README_ACCEPTANCE.md) 和 [docs/操作说明.md](docs/操作说明.md)。实际采集需要RIGOL DS2202A及匹配的VISA通信环境；数字扫描联合采集还需Logic 2及其Automation Server。第三方仪器软件从厂商获取，不在仓库重复分发安装程序。

## 已归档结果

- **采样率**：`measurements/reports/lrck/`，两次LRCK结果约47999.5859Hz与47999.8658Hz。
- **复音**：`measurements/reports/polyphony/`，ALL64、四组GROUP、MUTE01/MUTE18，以及视频ALL64/MUTE64。检查结果为64/64、16/16或63/63，不代表全部64路静音均已实测。
- **延迟**：`measurements/reports/latency/full_key_budget_001/report.md`，钢琴24键84次的条件性误差预算；其余目录保留各次和吉他、编钟抽样分析。软件严格计量上界标志未验证，不将条件性包络宣称为校准保证值。

原始测试固件SHA256：
`2A1C5EA9A07E9421049F5E1623558A684046DF6744FAAC9D5258CDDCDEC18EF8`。

## 原始数据与源码

仓库保留全部测试软件Python源码、测试脚本、分析JSON/CSV、主要复音报告和示波器截图。为了控制Git体积，大型RAW波形、逻辑原始采集和完整图表在本次测试资料Release附件 `measurement-evidence-20261101.zip` 中，解压后将measurements目录与本目录合并，即可使用原始记录进行离线复核。尚未发布附件时可使用团队原始“测试软件.zip”。

部分历史HTML链接和JSON记录包含采集时的目录或旧编号，均保留用于溯源；仓库里的报告子集不保证每个历史链接均可用，复核应使用完整附件。原始数据不改写，`source_manifest.json`记录整理来源及文件哈希。

`config/settings.json`重置为空，避免携带采集电脑的IP与绝对路径；运行后由软件保存本机设置。原配置保留于团队原始压缩包。本次未连接硬件重新采集，离线单元测试结果另见 `validation/`。

## 本次离线核对

原测试集294项中292项通过，2项因提供的原包缺少测试辅助模块 `verify_scope_download.py` 报错。细节见 [validation](validation/README.md)。未修改软件源码或改变测量判据。
