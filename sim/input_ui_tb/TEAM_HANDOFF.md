# 成员 B：B0/B1/B2 公共协议修订交付

本提交将 B 的事件编号和音量参数出口对齐 `rtl/common/event_defs.vh`。B 子系统仍需 C 的事件队列和 A 的接收修复后才能整机联调。

## 接口现状与集成责任

|项目|B 当前行为|后续动作|
|---|---|---|---|
|NOTE_ON/OFF|使用公共宏 1 / 2；B 测试直接断言编码|C/A 按公共协议接收|
|音量|界面 0..127；参数出口 `round(volume*65535/127)`，默认 33026，最大 65535|A 直接按 16 位线性增益处理|
|事件接收|每个控制时钟可产生事件，16 键集中变化按顺序全部送出|C 增加带溢出检测的队列，A 修复同拍接收/消费；覆盖事件撞上 sample_tick|

`input_defs.vh` 只引用 C 维护的公共定义。本次未修改 rtl/common、rtl/system、project、constraint。B 的 input_top 需 system_ready；A/C 可接收后才拉高，初始化参数会早于 input_ready。首次联调建议 B/A 共用音频时钟和同步复位，显式设置 CLK_HZ 为实际频率；分时钟运行时需跨域队列/握手。input_top 的默认 INSTRUMENT_COUNT=1；B 的扩展测试显式设置为4。

## 交付内容与证据

- rtl/input：矩阵、消抖、音符映射、EC11、按压切换、联合 input_top。
- rtl/ui：参数管理、刷新通知、4x16 ASCII OLED内容。字体、SSD1306/I2C由C实现。
- sim/input_ui_tb：独立工程、13项自动测试、波形记录脚本、接线说明。
- evidence/stage2/B012：原始PASS文本、Gowin综合日志、真实VCD生成的波形截图。日志中的本机路径为历史验证环境，不是可移植运行路径。
- VCD/WDB、中间网表、软件安装包、第三方PDF不入仓库；运行run_tests.ps1可重新生成波形。

本修订在团队仓库用 XSim 复跑13项测试，全部通过；此前 input_top/oled_content 在Gowin1.9.12综合通过，修订后综合待复核。未完成整机布局布线、时序、上板、延迟与30分钟稳定性验收。tb_sensor仅验证禁用传感器的零值接口，B3尚未实现；HC-SR04为B2可选路线，本次选EC11。

## GPIO电压说明（必须与接线表一起看）

**所有本方案GPIO输入、输出和上拉使用3.3V逻辑；绝不把5V接入GPIO。** J13第11脚是底板的5V电源输出，不是可承受5V的GPIO。本方案不用此脚；J13第12脚为GND。EC11三路上拉和键盘四列上拉都接确认过的3.3V电源，不接5V。电阻并不会把5V上拉变成3.3V上拉。

详细J13脚号、FPGA球号、EC11的3个4.7kΩ及键盘4个10kΩ见同目录《B012交付与接线.md》。分配为B推荐方案，C需与现有板载音频/其他外设核对无冲突后写入整机CST；先断电接线。

实际底板为31005。J13信号与球号已按官方31005原理图第7、19页核对；详细接线见下述文档。

## 复现

在sim/input_ui_tb中执行 `./run_tests.ps1 -VivadoBin '你的Vivado/bin目录'`。不把tb文件放进综合。input_ui_sim.gprj列可综合源码，选择input_top顶层；OLED内容可单独选择oled_content。原B工程中两处目录关系与仓库布局一致，相对路径可用。
