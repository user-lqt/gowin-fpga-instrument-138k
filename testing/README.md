# 电子乐器测试软件与测量结果

## 启动

在Windows中安装Python（含Tkinter），运行 `python -m pip install -r requirements.txt`，双击 `start_instrument_acceptance.cmd`。程序不在启动时自动连接仪器。

软件提供复音、按键延迟、LRCK采样率、评分证据四页。操作步骤见 [README_ACCEPTANCE.md](README_ACCEPTANCE.md) 和 [docs/操作说明.md](docs/操作说明.md)。实际采集需要RIGOL DS2202A及匹配的VISA通信环境；数字扫描联合采集还需Logic 2及其Automation Server。第三方仪器软件从厂商获取，不在仓库重复分发安装程序。

## 已归档结果

- **采样率**：`measurements/reports/lrck/`，两次LRCK结果约47999.5859Hz与47999.8658Hz。
- **复音**：`measurements/reports/polyphony/`，ALL64、四组GROUP、MUTE01/MUTE18，以及视频ALL64/MUTE64。检查结果为64/64、16/16或63/63，不代表全部64路静音均已实测。
- **延迟**：当前完整附件中的钢琴正式原始记录为24键各3次，共72次，视频补测另列。仓库中 `full_key_budget_001` 为历史84次派生汇总，保留供相位分析和余量来源追溯。当前批次复核应从附件原始记录出发，吉他、编钟也应按当前原始文件识别批次。

原始测试固件SHA256：
`2A1C5EA9A07E9421049F5E1623558A684046DF6744FAAC9D5258CDDCDEC18EF8`。

## 原始数据与源码

**完整测试软件及全部原始数据已发布：**

- [下载完整压缩包（约816 MiB）](https://github.com/user-lqt/gowin-fpga-instrument-138k/releases/download/testing-archive-20261103/test-software-complete-20261103.zip)
- [Release页面](https://github.com/user-lqt/gowin-fpga-instrument-138k/releases/tag/testing-archive-20261103)
- [逐文件SHA256校验清单](https://github.com/user-lqt/gowin-fpga-instrument-138k/releases/download/testing-archive-20261103/test-software-complete-20261103.manifest.json)

这是团队提供的“测试软件.zip”原文件，未经删减或改写，包含2341个文件，其中原始采集文件750个。完整保留代码、配置、历史索引、分析报告、截图、延迟CH1/CH2二进制波形、逻辑分析仪数字CSV、LRCK及复音原始数据，以及原包自带的其他文件。Git仓库内保留便于浏览的软件和结果子集，大文件通过上述Release下载。

压缩包大小：`855363391` 字节。SHA256：

```text
871d9c24622f25bf3d5d2fd744d597131bdef6c5b5728bd97a6d9fec8d9dc2ad
```

解压后进入“测试软件”目录使用，或将完整附件中的 `measurements` 目录合并到仓库 `testing/measurements`。复核时保留原始目录结构，使 `joint_capture.json` 的相对路径能够找到对应逻辑采集。采集电脑的旧绝对路径及历史编号按原样归档，迁移或运行前按软件说明核对。

Windows文件校验：

```powershell
Get-FileHash .\test-software-complete-20261103.zip -Algorithm SHA256
```

部分历史HTML链接和JSON记录包含采集时的目录或旧编号，均保留用于溯源；仓库里的报告子集不保证每个历史链接均可用，复核应使用完整附件。原始数据不改写，`source_manifest.json`记录整理来源及文件哈希。

`config/settings.json`重置为空，避免携带采集电脑的IP与绝对路径；运行后由软件保存本机设置。原配置保留于团队原始压缩包。本次未连接硬件重新采集，离线单元测试结果另见 `validation/`。

## 本次离线核对

原测试集294项中292项通过，2项因提供的原包缺少测试辅助模块 `verify_scope_download.py` 报错。细节见 [validation](validation/README.md)。未修改软件源码或改变测量判据。
