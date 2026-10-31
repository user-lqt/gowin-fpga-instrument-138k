# 最终工程快速上手

## 1 选择正确文件

工程：`final/project/integrated_instrument_64/integrated_instrument_64.gprj`。

烧录：`final/project/integrated_instrument_64/impl/pnr/integrated_instrument_64.fs`。

打开工程时，顶层应为 `instrument_64_top`，器件为 `GW5AST-LV138PG484AC1/I0`。内部仍引用 `instrument_24_rgb_top` 参数化公共顶层，文件名中24表示实体琴键数量，不表示只有24复音；外层设置 `VOICE_COUNT=64`。

本仓库已经提供最终固件。仅使用现有固件时无需重新综合或布局布线。本次整理没有自动启动Gowin、下载器或示波器。

## 2 校验

```powershell
python -B tools/verify_release.py
Get-FileHash final/project/integrated_instrument_64/impl/pnr/integrated_instrument_64.fs -Algorithm SHA256
```

SHA256应为 `2A1C5EA9A07E9421049F5E1623558A684046DF6744FAAC9D5258CDDCDEC18EF8`。

根目录的发布校验工具适用于本次最终整理。`final/tools/verify_package.py` 配套的是原目录中历史 `package_manifest.json`，该旧清单含已删除的32声部项目等历史条目，不作为本次发布的完整性标准。原文件均保留，未为了“通过校验”改写旧记录。

## 3 硬件与声音

断电核对[硬件说明](HARDWARE.md)。连接双触点键盘、编码器、外置PCM5102A与RGB屏，所有外部数字接口按3.3V电平与共同地连接。

声音从**外接PCM5102A的LINE OUT**进入有源音箱或功放；不是原板载耳机口。先降低音箱音量再上电。

若需要烧录，在Gowin Programmer检测器件后选择上面的最终 `.fs`。SRAM配置掉电失效；需掉电保持时按实物Flash与厂商流程选择正确模式，不根据仓库路径推测Flash型号。

## 4 顺序检查

1. 屏幕显示演奏页面；按实体键能发声，松开后按音色释放。
2. EC11_A旋转调音量、短按切音色；EC11_B短按切换六页。
3. 慢快按同一键，观察力度并试听差异；测试所有24键。
4. 检查滑音、摇杆弯音、FSR颤音和FX。
5. 进入SONG，本地选曲并长按启动，按对目标键后灯继续指引。
6. 最后连接手机，测试新曲谱、映射与演奏事件回传。
7. TEST采用持续多频点输出，先降低音箱音量，再验证ALL/GROUP/MUTE。

界面数值与物理按键不一致时先确认正在运行的固件哈希与版本。不要混用旧分支的顶层、引脚表和32声部固件。
