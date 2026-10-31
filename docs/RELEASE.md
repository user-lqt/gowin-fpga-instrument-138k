# 最终版本整理说明

日期：2026年11月1日。

## 最终基线与固件

源目录由用户指定为 `E:\Gowin\Final\FPGA_Instrument_20261031`。最终发布固件由用户进一步明确为：

```text
project/integrated_instrument_64/impl/pnr/integrated_instrument_64.fs
SHA256 2A1C5EA9A07E9421049F5E1623558A684046DF6744FAAC9D5258CDDCDEC18EF8
42340871 bytes
```

仓库中对应 `final/` 下同一路径，不改名、不转换内容、不重新生成。工程相对路径结构和实现配置保留。

原目录另有两份旧固件备份，哈希分别为47BCF469…D56FB794、6EDA1725…E576A2；都不同于最终指定文件。本次没有将旧备份列为下载候选，也没有按旧README误选固件。

## 与此前仓库的区别

1. 根目录首页由早期阶段分工骨架，更新为可直接打开、烧录、查接线的最终工程入口。
2. 三个成员已集成的功能使用用户最终快照，不再次混合早期分支RTL。
3. `final/` 收录完整有效工程输入、最终FS、同目录已有PNR报告、K230程序、PC工具、仿真与原资料。
4. `docs/` 新建统一方案、硬件、58端口引脚表、六页操作、蓝牙协议和验证导航。
5. `companion/` 单列此前上传的手机网页和本机现有ESP桥接源码，注明各自来源，避免宣称其属于Final目录。
6. 原main工作树整体归档到 `archive/main-before-final/`，开发分支与Git提交历史保留。
7. 增加本次来源及SHA256清单和只读校验工具，不改旧清单伪造通过记录。

## 收录范围

所有收录的Final原文件均逐字节一致。为适配源码仓库，仅不收录大型实现数据库（其中`.pr`约274MB）、仿真可执行缓存、IDE个人状态、历史builds试验目录，以及用户已排除的旧固件备份。最终 `.fs`、本轮引脚/资源/时序报告、工程 `impl/*process_config.json` 保留；没有删除本机Final中的任何文件。

逐个源文件的大小、哈希、是否收录及原因都在 `release/manifest.json` 的 `source_inventory`，可完整核对整理边界。根目录 `.gitattributes` 对 `final/**`、`companion/**` 禁用换行转换，保证Git存储和克隆不把原CRLF变成LF。

原Final包README、旧manifest与旧开发脚本保留，部分引用早期bitstream和32版；它们是历史资料。发布和校验以仓库根README、本文及 `tools/verify_release.py` 为准，不执行旧构建脚本完成本次整理。

## 未执行的工程操作

本次没有改动RTL、CST、SDC、ROM、Gowin配置或FS；没有综合、布局布线、下载、连接示波器或手机。不改变K6上传限制或K22力度修正等已有行为。用户交付的Final目录始终只读。

保留的历史报告和仿真结论按原日期归档，不升级为本次实测。新文档已区分设计目标、数字仿真、PNR报告、模拟输出和现场延迟。
