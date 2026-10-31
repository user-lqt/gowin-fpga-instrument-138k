# 版本记录

## 2026-11-01 仓库整理

活动分支收拢为 `main`。删除工作目录中的旧分支快照、重复说明、中间验证日志及过期打包脚本；保留系统方案、接线、操作、通信及测试文档。

最终FPGA工程、约束、ROM、固件，以及K230、ESP与网页程序保持原字节。

## 历史版本

- `final-20261101`：整理前的完整交付快照，含旧阶段资料。
- `archive/development-20261101`：14个开发分支的历史归档。该标签的提交以各分支末端为父提交，仅用于保存历史，不是功能合并。

| 原分支 | 归档提交 |
| --- | --- |
| `codex/integrated-instrument` | `a4df0dd8fe15a2b40f214dd205e96e2e45b2747b` |
| `dev-audio` | `6035c116207c51a1fe39e66c6c768080184737bc` |
| `dev-input` | `14b7f09d1ba10685d67918a5c86333ba604b2c2d` |
| `dev-system` | `9a302a5e6aa27d55dc44951a545dcbe21189aaa5` |
| `feat/fsr-mcp3008` | `508480ca96b5a13fb2e109b5940f66209471a093` |
| `feature/c-joystick-bend-test-20261015` | `63ef83b38afce4d1a961b3f8b48716b63a921f48` |
| `feature/c-k230-uart-20261022` | `1140e69647dd1d4e2e4a9fc23bbf945ea2c2fc9c` |
| `fix/ab-order` | `4e708a0fae404b36cfde51c32b97540570a247fb` |
| `fix/b-integrated-20261016` | `2b47168907d6cbe6c8c2d251dacc7d1938750e6a` |
| `fix/c-legato-glide-20261021` | `b0fa52857229316629f1cb3bfcb8d85ec3241c7d` |
| `integration/b-complete-20261011` | `dbc77e5de698c6f59c5d27d4139bca24e037b8d9` |
| `integration/b-current-20261015` | `75e652fa900900c3facd5a7f67c072cc5556ecec` |
| `integration/b-stage3-fsr` | `732163d110d4c4bba3a2c54bc0ce42cb52228bb7` |
| `integration/c-stage3` | `841892c51a33f09fe9aa0f85c2a85b35575d8131` |

需要查看历史时按提交检出；需要恢复开发分支时执行：

```sh
git fetch origin --tags
git switch -c dev-audio 6035c116207c51a1fe39e66c6c768080184737bc
```
