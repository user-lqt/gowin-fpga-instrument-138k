# waveforms/ —— 仿真波形配置目录

> 只提交**波形配置**（保存的信号列表、触发条件、显示分组），**不提交波形数据**。

## 命名规则

```
waveforms/tb_audio_core/      成员 A
waveforms/tb_input/           成员 B
waveforms/tb_encoder/         成员 B
waveforms/tb_sensor/          成员 B
waveforms/tb_ui/              成员 B
waveforms/tb_system/          成员 C
```

## 每个 testbench 建议保存的信号

| testbench | 重点观察信号 |
|---|---|
| `tb_audio_core` | `event_valid`、`event_type`、`note_id`、`audio_core_valid`、`audio_left[23:0]`、`active_voice_count`、`overload_flag`、ADSR 状态机 |
| `tb_input` | 行列扫描电平、`key_state`、`event_valid`、`event_type`、`note_id`、抖动脉冲 |
| `tb_encoder` | `enc_a`、`enc_b`、方向、步进计数、限幅值 |
| `tb_sensor` | 原始值、滤波后值、校准值、断线默认值 |
| `tb_ui` | `ui_page`、`ui_param_value`、`ui_dirty` |
| `tb_system` | `sample_tick`、`i2s_bck`、`i2s_lrck`、`i2s_data`、`system_error`、`audio_locked` |

## 必须留存的波形截图（用于 evidence/）

1. `tb_audio_core`：单音 NOTE_ON → 稳定正弦 → NOTE_OFF 平滑释放
2. `tb_audio_core`：4 复音同时发声不溢出
3. `tb_input`：一次按下只产生一个 NOTE_ON
4. `tb_system`：LRCK 周期 = 1/48 kHz，BCK = 64 × LRCK，数据对齐正确

## 禁止提交

- `*.vcd`、`*.wlf`、`*.sav` 等波形数据文件（已在 `.gitignore` 中排除）
- 体积大的截图（先压缩或用关键片段）
