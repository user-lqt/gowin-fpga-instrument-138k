# 成员 B：B0/B1/B2 上传交付，待接口适配

本提交保存已经完成并独立测试的 B 子系统，供 C 审查和集成。**不是与当前 common/event_defs.vh 直接兼容的整机版本，不能未经适配直接合并接线下载。**

## C 首先处理的三个差异

|项目|本地 B 已测试版本|仓库公共协议|集成动作|
|---|---|---|---|
|NOTE_ON/OFF|0 / 1|1 / 2|以 C 的公共协议为准，统一 B 宏和测试；避免同时包含两个不同定义|
|音量|0..127，默认64|0..65535线性幅值|保留UI的0..127，参数出口映射为 round(volume*65535/127)，或团队明确另定；不可直接把64当16位增益|
|事件接收|每个控制时钟接受valid，允许连续拍|A每个sample_tick至少接受一个事件|由集成设计明确队列和跨时钟处理；不能把单拍valid直接接只在sample_tick读输入的模块|

input_defs.vh 是独立演示协议，不是公共协议的替代品。此次未修改 rtl/common、rtl/system、project、constraint，也未替 C 冻结接口或打阶段标签。B 目前的 input_top 需 system_ready；A/C 可接收后才拉高，初始化参数会早于 input_ready。100MHz系统时钟下设置 CLK_HZ=100000000，默认50MHz不能直接照搬。跨域需要队列/握手，不是仅对valid打两拍。

## 交付内容与证据

- rtl/input：矩阵、消抖、音符映射、EC11、按压切换、联合 input_top。
- rtl/ui：参数管理、刷新通知、4x16 ASCII OLED内容。字体、SSD1306/I2C由C实现。
- sim/input_ui_tb：独立工程、13项自动测试、波形记录脚本、接线说明。
- evidence/stage2/B012：原始PASS文本、Gowin综合日志、真实VCD生成的波形截图。日志中的本机路径为历史验证环境，不是可移植运行路径。
- VCD/WDB、中间网表、软件安装包、第三方PDF不入仓库；运行run_tests.ps1可重新生成波形。

已在原交付目录用XSim通过13项测试；input_top/oled_content已在Gowin1.9.12综合通过。未完成整机布局布线、时序、上板、延迟与30分钟稳定性验收。tb_sensor仅验证禁用传感器的零值接口，B3尚未实现；HC-SR04为B2可选路线，本次选EC11。

## GPIO电压说明（必须与接线表一起看）

**所有本方案GPIO输入、输出和上拉使用3.3V逻辑；绝不把5V接入GPIO。** J13第11脚是底板的5V电源输出，不是可承受5V的GPIO。本方案不用此脚；J13第12脚为GND。EC11三路上拉和键盘四列上拉都接确认过的3.3V电源，不接5V。电阻并不会把5V上拉变成3.3V上拉。

详细J13脚号、FPGA球号、EC11的3个4.7kΩ及键盘4个10kΩ见同目录《B012交付与接线.md》。分配为B推荐方案，C需与现有板载音频/其他外设核对无冲突后写入整机CST；先断电接线。

官方31002原理图来源：https://dl.sipeed.com/shareURL/TANG/Mega_138K_60K/02_Schematic/DOCK/archived

## 复现

在sim/input_ui_tb中执行 `./run_tests.ps1 -VivadoBin '你的Vivado/bin目录'`。不把tb文件放进综合。input_ui_sim.gprj列可综合源码，选择input_top顶层；OLED内容可单独选择oled_content。原B工程中两处目录关系与仓库布局一致，相对路径可用。
