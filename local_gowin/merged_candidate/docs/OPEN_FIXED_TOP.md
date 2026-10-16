# 本次请使用新工程入口

打开 project/instrument_fixed_top/instrument_fixed_top.gprj。
该入口使用相同源码和约束，设备型号不变；已单独放置完整的 Gowin process_config.json，TopModule 明确为 instrument_24_rgb_top。
新工程名为 instrument_fixed_top，没有继承旧工程的用户缓存和错误综合网表。

旧入口的配置曾在补回后再次变成 TopModule 空字符串，旧综合日志仍将 rgb_lcd_800x480 选为顶层。
因此这次交付新入口，不依赖旧项目的内存状态。
打开新入口后，可先在综合配置中确认 Top Module 为 instrument_24_rgb_top，再自行运行 Synthesize。
检查新综合日志中的 Current top module is "instrument_24_rgb_top" 后再运行 Place & Route。

本次没有启动综合、布局布线或烧录；仅核对完整配置、相对源文件路径及顶层名称。
