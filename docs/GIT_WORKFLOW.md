# 三人协作规范 · Git Workflow

> 归属：成员 C 维护。本文是"谁改哪里、怎么提交、怎么合并"的唯一规定。
> 违反边界规定的提交（比如 A 改了 `rtl/system/`）会被要求回退重做。

---

## 1. 分支模型

```
main                    ← 永远可编译、可提交的稳定版本。只接受通过 PR 的合并
├─ dev-audio            ← 成员 A 的日常开发分支
├─ dev-input            ← 成员 B 的日常开发分支
├─ dev-system           ← 成员 C 的日常开发分支
└─ feature/<owner>-<topic>   ← 可选：单个人做大功能时从自己分支切出来
```

| 分支 | 谁推 | 规则 |
|---|---|---|
| `main` | 无人直接推 | 只通过 PR 合并；每次合并必须打标签 |
| `dev-audio` | A | A 的常规工作都推到这里 |
| `dev-input` | B | B 的常规工作都推到这里 |
| `dev-system` | C | C 的常规工作都推到这里（C 也负责合并他人的 PR） |

**打标签的时机**（标签只能由 C 打）：

```bash
git checkout main
git merge --no-ff dev-audio        # 走 PR 的话由网页完成合并
git tag -a stage1-minimal -m "阶段1：三条独立最小链路验收通过"
git push origin main --tags
```

| 标签 | 含义 |
|---|---|
| `stage0-freeze` | 接口、工程、平台信息冻结 |
| `stage1-minimal` | 单音合成 + 键盘输入 + I2S 出声，三条链路独立验证通过 |
| `stage2-baseline` | **保底线**：≥4 复音、2 维交互、≤10 ms、可提交版本 |
| `stage3-award` | 冲奖扩展验收通过 |
| `stage4-final` | 比赛现场冻结版本 |

---

## 2. 目录所有权（违反即需回退）

| 路径 | 所有者 | 其他人 |
|---|---|---|
| `rtl/audio_core/`、`sim/audio_core_tb/` | **A** | 只读 |
| `rtl/input/`、`rtl/ui/`、`sim/input_ui_tb/` | **B** | 只读 |
| `rtl/system/`、`sim/system_tb/` | **C** | 只读 |
| `rtl/common/`、`project/`、`constraint/` | **C** | 只读（但 C 改 `event_defs.vh` 必须通知 A/B） |
| `docs/`、`README.md` | **C** | 可提 PR 修改 |
| `tools/`、`waveforms/`、`evidence/` | **共用** | 用子目录区分 |

**共用目录的命名隔离规则**（避免三人互踩）：

```
waveforms/tb_audio_core/...      A 的波形
waveforms/tb_input/...           B 的波形
waveforms/tb_system/...          C 的波形
evidence/stage0/A_...            A 的验收证据
evidence/stage0/B_...
evidence/stage0/C_...
```

**每个人用独立文件，绝不两人同时编辑同一文件。** 典型冲突源：

| 高危文件 | 处理方式 |
|---|---|
| `*.gprj`（Gowin 工程文件） | **三人各一份，永不共用**：`audio_core_sim.gprj` / `input_ui_sim.gprj` / `audio_system_sim.gprj` / `synth_top.gprj` |
| `rtl/common/event_defs.vh` | 只有 C 能改；改前在群里发变更说明 |
| `synth_top.v` | 只有 C 能改 |
| `.cst` / `.sdc` | 只有 C 能改 |

---

## 3. 提交信息规范

格式：`<type>(<scope>): <中文描述>`

| type | 用于 |
|---|---|
| `feat` | 新功能 |
| `fix` | 修 bug |
| `refactor` | 重构（不改行为） |
| `sim` | 只改 testbench / 仿真 |
| `docs` | 文档 |
| `constraint` | 管脚/时序约束 |
| `chore` | 杂项（目录、脚本、gitignore） |

| scope | 对应 |
|---|---|
| `audio` | A 的音频核心 |
| `input` | B 的输入链路 |
| `ui` | B 的界面 |
| `system` | C 的系统平台 |
| `common` | 共享接口 |

**示例**

```
feat(audio): 实现 32 位相位累加器与波表寻址
sim(audio): 增加 tb_audio_core 的四复音自动检查
fix(audio): 修正 ADSR 在 NOTE_OFF 后立即静音的硬切问题
feat(input): 实现 4x4 矩阵键盘扫描与消抖
constraint(system): 按实物核对 I2S 三线管脚并更新 .cst
docs(common): 接口冻结卡补充混音位宽分级缩放说明
```

**一次提交只做一件事。** 不要把"加功能 + 改格式 + 调管脚"塞进一个提交。

---

## 4. 日常操作流程

```bash
# 0. 一次性配置
git config user.name  "你的名字"
git config user.email "你的邮箱@example.com"

# 1. 开工前同步主干
git checkout dev-audio
git fetch origin
git merge origin/main          # 把 main 的更新拉进来

# 2. 干活（只改自己目录）
#    ... 编辑文件 ...

# 3. 提交前自检
git status                     # 确认没有误改他人目录
git diff                       # 确认改动内容符合预期

# 4. 提交并推送
git add rtl/audio_core/phase_acc.v sim/audio_core_tb/tb_audio_core.v
git commit -m "feat(audio): 实现 32 位相位累加器与波表寻址"
git push
```

### 提交前自检清单（每次都要过一遍）

- [ ] 只改了自己拥有的目录？
- [ ] 仿真跑通、有 PASS 输出？（贴到 PR 里）
- [ ] 没有提交 `impl/`、`*.fs`、bitstream、临时文件？
- [ ] 没有提交别人的 PDF、安装包、大文件？
- [ ] 若改了接口相关字段，`event_defs.vh` 版本号 +1 且已通知 A/B？

---

## 5. Pull Request 与合并

功能做完 → 发 PR 到 `main`：

```bash
gh pr create --base main --head dev-audio \
  --title "stage1(audio): 单音 DDS 通路" \
  --body "## 做了什么
- note_to_fc / phase_acc / wavetable / oscillator

## 证据
- tb_audio_core 通过，波形存于 waveforms/tb_audio_core/
- 频率实测：A4=440.0Hz，误差 < 0.5 音分

## 综合情况
- 资源：LUT xxxx，DSP xx，BSRM xx
- 时序：WNS x.xx ns

## 需要人工确认
- 上板后实际听感"
```

**PR 必须包含三样东西**：做了什么 / 证据在哪 / 需要谁确认什么。

**合并方式**：由 **C** 审核并合并（C 是集成责任人）。合并用 `--no-ff` 保留合并记录。

**PR 阻塞条件**（有任一条就不合并）：

1. 改动越界到他人目录
2. 没有仿真证据或仿真 FAIL
3. 破坏 `stage2-baseline` 的回归测试
4. 接口字段变更未经 A/B 确认

---

## 6. 冲突处理

**冲突的本质是"两个人改了同一段"。** 预防 > 解决：

| 预防手段 | 做法 |
|---|---|
| 分工隔离 | 每人独立目录 + 独立 `.gprj` |
| 频繁同步 | 每天开工先 `git merge origin/main` |
| 小步提交 | 一次提交一个逻辑变更，PR 尽量小 |
| 提前沟通 | 要动共享文件前先在群里说 |

**真遇到冲突时**：

```bash
git merge origin/main
# 冲突文件会列出，逐个打开
#   <<<<<<< HEAD        你的版本
#   =======             分界线
#   >>>>>>> origin/main 主干的版本
# 手工合并成正确结果，删掉三行标记
git add <解决后的文件>
git commit
```

**特殊文件冲突处理**

- **`*.gprj` 冲突**：不要手工合并 XML。**以能打开的那一份为准**（`git checkout --ours` 或 `--theirs`），然后重新在 IDE 里确认文件列表。
- **`event_defs.vh` 冲突**：**必须以 C 的版本为基础**，同时把双方的字段都保留（作为兼容扩展），版本号 +1。
- **真解不了**：`git merge --abort` 退回原状，找 C 一起处理。

---

## 7. 仓库不接收的文件

见根目录 `.gitignore`。**核心原则：只提交能人工阅读和审查的源码级内容。**

| 不要提交 | 原因 |
|---|---|
| `impl/`、`*.fs`、`*.ipc`、`*.log`、`.temp/` | 云源生成的中间产物，体积大且可再生成 |
| `*.bit`、`*.fs`（bitstream） | 体积大；比赛提交单独归档 |
| PDF 手册、`*.rar`、`*.zip`、安装包 | 大二进制，无法 diff |
| 逻辑分析仪安装包、教程压缩包 | 同上（工作区 `阶段一/` 里就有 250MB 的安装包） |
| 波形数据库 `*.vcd`、`*.sav` | 体积大；只在 `evidence/` 留截图 |

**要提交的**：RTL、testbench、`.gprj`、`.cst`、`.sdc`、`.vh`、文档、脚本、波形配置（不是波形数据）、截图、综合/时序报告摘要。

---

## 8. 一次性仓库配置（由仓库主执行）

```bash
# 建远端（已由 gh 完成）
gh repo create gowin-fpga-instrument-138k --public \
  --description "高云 Tang Mega 138K 实时多音色合成电子乐器 · 2026 嵌赛 FPGA 赛道选题二" \
  --source . --remote origin

# 邀请两位成员（把 USERNAME 换成他们的 GitHub 账号）
gh api -X PUT repos/:owner/gowin-fpga-instrument-138k/collaborators/USERNAME -f permission=push

# 保护 main：禁止直接推送，必须走 PR
gh api -X PUT repos/:owner/gowin-fpga-instrument-138k/branches/main/protection \
  -H "Accept: application/vnd.github+json" \
  -F "required_pull_request_reviews[required_approving_review_count]=1" \
  -F "enforce_admins=false" -F "required_status_checks="
```

> 公开仓库的 `main` 建议开启保护，避免误推把主干搞坏。

---

## 9. 每个人的上手三步

```bash
# 1. 克隆
git clone https://github.com/user-lqt/gowin-fpga-instrument-138k.git
cd gowin-fpga-instrument-138k

# 2. 配置身份 + 切到自己的分支
git config user.name  "你的名字"
git config user.email "你的邮箱@example.com"
git checkout dev-audio     # A
git checkout dev-input     # B
git checkout dev-system    # C

# 3. 按顺序读三份文件
#    README.md
#    docs/PLATFORM_TANG_MEGA_138K.md
#    docs/INTERFACE_FREEZE.md
#    然后读自己的任务书
```

任何不确定的地方，**先在群里问，不要猜着改别人的文件**。

---

## 10. 本机 Git HTTPS 崩溃记录（2026-09-25）

在这台 Windows 电脑上，默认 Git 是 `D:\Program_Files_D\Git\cmd\git.exe`（2.50.1.windows.1）。执行 HTTPS 远端操作时，`git-remote-https.exe` 曾多次崩溃，并弹出 Visual Studio 即时调试器。弹窗是系统 `AeDebug` 接管异常后的表现，不是 GitHub 要求调试；没有找到对应的 WER 崩溃报告。

已确认系统 `PATH` 中的 `C:\mingw64\bin` 排在该 Git 自带运行库目录之前，且其中的 `libcurl-4.dll`、`libiconv-2.dll` 等与 Git 自带版本不同。临时把 Git 自带的 `mingw64\bin`、`usr\bin` 提到 `PATH` 最前面后，同一旧版 Git 的 `ls-remote` 成功；Codex 自带 Git 2.53.0.windows.3 在原有仓库、代理和凭据条件下也成功。因此应按运行库搜索顺序冲突处理；目前不能确定具体是哪一个 DLL 导致崩溃。

**后续在本机执行 Git 网络命令，优先显式调用已验证的新版 Git：**

```powershell
$gitExe = 'C:\Users\lenovo\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd\git.exe'
& $gitExe ls-remote origin refs/heads/main   # 只读连通性检查
# 确认本地分支、提交和目标远端后，再以同一 $gitExe 执行 fetch / push
```

若必须使用旧版 Git，仅在当前 PowerShell 命令段内临时调整 `PATH`，并在结束时恢复：

```powershell
$oldPath = $env:PATH
try {
    $env:PATH = 'D:\Program_Files_D\Git\mingw64\bin;D:\Program_Files_D\Git\usr\bin;' + $oldPath
    & 'D:\Program_Files_D\Git\cmd\git.exe' ls-remote origin refs/heads/main
} finally {
    $env:PATH = $oldPath
}
```

不要永久修改全局 `PATH`，以免影响其他 MinGW 程序；也不要以关闭 TLS 证书校验来处理此类进程崩溃。若出现弹窗，先检查命令退出状态及 `git status`、`git rev-parse HEAD`、`ls-remote` 的结果，再决定是否重试推送，避免重复操作。
