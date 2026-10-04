# 三音色试听版

2026-09-27：三种实时振荡器音色已接入整机，并生成独立固件。该版尚未上板试听；OLED 黑屏问题仍需单独排查。

| 音色编号 | 波形 | 1 秒 C4 仿真试听 |
|---|---|---|
| 0 | 正弦 | `output/timbres/sine_c4.wav` |
| 1 | 三角 | `output/timbres/triangle_c4.wav` |
| 2 | 锯齿 | `output/timbres/saw_c4.wav` |

WAV 为 `tb_timbres` 输出的 RTL 采样，经 `tools/export_timbres.py` 打包成 48 kHz、16-bit、单声道文件；它们不是板载 DAC 的录音。

## 上板操作

试听版固件：`project/instrument_timbres_top/impl/pnr/instrument_timbres_top.fs`。原可演奏固件 `project/instrument_top/impl/pnr/instrument_top.fs` 未被本次构建覆盖。

复位后默认为音色 0，编码器旋转控制音量。按一次编码器切到音色页，顺时针转一格选 1，再转一格选 2；反向旋转可退回。再按一次回到音量页。音色编号在 0～2 之间限幅。已按住的音符保持原音色，松开后重新按键才能听到新音色。OLED 若仍黑屏，可以复位并按上述步骤计数试听；旋转方向以实际编码器接线和听感核对。

## 验证

- `tools/verify_stage2.ps1 -Tests tb_timbres` 通过：三音色不同、持续音切换不跳变、释放正常、无效编号忽略，四声部锯齿满音量不削波。
- `tb_voice`、`tb_audio_core_a2`、`tb_audio_core`、`tb_stage2_controls` 回归通过。
- Gowin V1.9.12 综合、布局布线、固件生成通过。音频时钟 12.288 MHz，Fmax 23.006 MHz；建立/保持违例端点均为 0。Logic 5310、FF 1223、BSRAM 16、DSP 11。
- 固件大小 36,309,161 字节，SHA256 `0AC4E1524215CF58908307D7CA2270B3BDF4AAE71FE400F12F162B69AE2C8E03`。

复现：运行 `tools/verify_stage2.ps1 -Tests tb_timbres`，再运行 `python tools/export_timbres.py` 和 `E:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe tools/build_instrument_timbres.tcl`。
