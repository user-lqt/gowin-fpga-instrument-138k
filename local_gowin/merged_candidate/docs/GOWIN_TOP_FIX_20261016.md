# Gowin 顶层配置修复

用户首次综合日志记录：`Current top module is "rgb_lcd_800x480"`。
这个屏幕子模块不是整机顶层，随后整机 CST 出现大量 CT1135 端口不存在错误。
原因是提取工程时遗漏了 Gowin 保存在 impl 目录中的 process_config.json。

已补回 `project/instrument_velocity_32_two_timbres/impl/instrument_velocity_32_two_timbres_process_config.json`，显式指定 `TopModule=instrument_24_rgb_top`。
这份 JSON 是工程设置，复制工程时必须保留；其余综合与布线产物不必保留。
已在 .gitignore 中单独保留此文件。

关闭当前工程，不保存内存中的旧工程配置，再打开原 gprj。
检查 Synthesis 的 Top Module 为 instrument_24_rgb_top；若软件仍显示旧值，在配置中手动改为此值再保存。
重新运行 Synthesize，再运行 Place & Route。不能直接重用原来屏幕子模块的综合网表。
新综合日志应显示 `Current top module is "instrument_24_rgb_top"`。

本次只补工程配置，没有启动综合或布局布线。之前 Icarus 顶层结构编译显式使用 -s 指定顶层，不能替代对 Gowin 自身工程配置的检查。
