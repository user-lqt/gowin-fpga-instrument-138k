# 扩展验证记录 2026-10-15

工程：`project/instrument_velocity_32_two_timbres/instrument_velocity_32_two_timbres.gprj`。

本次不运行综合、布局布线和烧录；资源、时序、实板音效与手机实连需后续验收。

## 已通过

- Icarus Verilog：`tools/verify_extensions.ps1`，六项测试全部PASS。
- `tb_extensions`：脱机启动、节奏预备与休止、GOOD/MISS、下载事务、K6拒绝、重复映射拒绝、同拍音符合并、录制时间戳、512事件容量和溢出、实际UART回包。
- `tb_ble_song_uart`：真实串行输入、选曲、无效帧及音符开关回归。
- `tb_lesson_guide`：茉莉花54音、指纹副歌60音、无K6、错键/长按、完成与重入。
- `tb_keyboard_led_strip`：49灯传输、24键映射、退出熄灭与重入。
- `tb_controls_display`：EC11_B短长按、1/2/3本地选曲循环、分析频点选择、参数页面循环。
- `tb_audio_visualizer`：750Hz频点、XY点阵初始化、静音、复位。
- Node：`tools/phone/protocol_test.cjs`，通知分片/混合、校验、曲谱校验、时间戳与MIDI导出PASS。
- 顶层Icarus编译展开通过，忽略厂商PLL黑盒；不代表Gowin综合/时序通过。
- 800×480主屏及分析页仿真截图已人工检查。截图使用合成输入，不是实板照片。

日志：`sim/audio_core_tb/build/extensions/*.log`。EC11测试有Icarus对testbench force语句的兼容提示，断言通过。
XSim启动停滞，已终止本次启动的进程，改用Icarus完成测试。

## 交付边界

手机网页已编写，尚未部署HTTPS站点；Android Chrome实连与连续传输未验证。
第三曲槽、映射和录制均为RAM，复位或掉电清除。
记录回传是音符事件，可导出MIDI，不是PCM音频录音回传。
内置节奏是简化训练版；不包含图片识谱、互联网曲库后台或持久化存储。
频谱为16个选定DFT频点，幅度未标定dB；XY为单声道延迟图。

按 `EXTENSIONS_PROTOCOL.md` 顺序进行实板验收：脱机选曲→节奏→下载第三曲→键位自定义→录制回传。
