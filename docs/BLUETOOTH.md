# 蓝牙与手机

## 连接

ESP32-C3 GPIO21 TX接FPGA C18，GPIO20 RX接FPGA C19，共地；串口115200/8N1，3.3V逻辑。ESP控制台使用USB Serial/JTAG。

将 [phone目录](../companion/phone/) 部署到HTTPS静态站点，保留文件相对位置。Android Chrome开启蓝牙后打开网页，点击连接并选择设备。电脑本机可使用localhost；iPhone Safari不支持本网页所需的Web Bluetooth。

ESP使用ESP-IDF与NimBLE，工程见 [esp32c3](../companion/esp32c3/)。K230使用另一条UART，部署见[说明](../final/k230/README.md)。

## 网页部署

仓库已包含 `.github/workflows/pages.yml`，仅发布 `companion/phone/`。

1. 仓库所有者打开 Settings → Pages，将 Build and deployment 的 Source 设为 GitHub Actions。
2. 在 Actions 中打开 Bluetooth web page，选择 Run workflow → main。
3. 部署成功后使用任务给出的网页地址；默认地址为 `https://user-lqt.github.io/gowin-fpga-instrument-138k/`。

后续更新网页会自动部署。私有仓库需账号套餐支持GitHub Pages；网页发布的访问范围按Pages设置确认。上述地址在部署成功前不可用。

## BLE与命令

| 项目 | UUID |
| --- | --- |
| 服务 | `6e400001-b5a3-f393-e0a9-e50e24dcca9e` |
| RX写入 | `6e400002-b5a3-f393-e0a9-e50e24dcca9e` |
| TX通知 | `6e400003-b5a3-f393-e0a9-e50e24dcca9e` |

调试器订阅TX，向RX写入HEX字节。命令格式 `A5 CMD A B CHECK`，CHECK为前四字节异或。每条控制命令等待FPGA的A6回执后再发送下一条。

| 操作 | 完整帧 |
| --- | --- |
| MIDI60按下，力度100 | `A5 90 3C 64 6D` |
| MIDI60松开 | `A5 80 3C 00 19` |
| 启动曲目1 | `A5 B0 01 00 14` |
| 启动曲目2 | `A5 B0 02 00 17` |
| 启动下载曲目3 | `A5 B0 03 00 16` |
| 自由练习 | `A5 B1 00 00 14` |
| 节奏练习 | `A5 B1 01 00 15` |
| 80 BPM | `A5 B2 50 00 47` |
| 停止指引 | `A5 B3 00 00 16` |
| 恢复默认键位 | `A5 D1 00 00 74` |
| 开始记录 | `A5 E0 00 00 45` |
| 停止记录 | `A5 E1 00 00 44` |
| 取回记录 | `A5 E2 00 00 47` |
| 查询状态 | `A5 F0 00 00 55` |

选曲前先进入SONG；第三槽需先上传有效曲谱。

## 下载曲谱

txt/csv每行两列：物理键号、时值。键号0为休止，1–24为实体键；时值1–32，以八分音符为单位，最多128项。

```text
5 2
5 2
8 2
10 4
0 2
```

协议顺序：C0（A=项数）开始，C1（A=键号、B=时值）逐项发送，C2提交；C3取消。先停止当前指引，上传完成后启动第三槽。

当前固件和配套网页仍拒绝下载键号6；K6本地演奏不受影响。

## 键位与演奏记录

D0设置键位：A=物理键号1–24，B=MIDI 0–127，不能与其他键重复。D1恢复默认60–83。修改前松开全部琴键；LED始终跟随物理键号。

记录操作：开始 → 演奏 → 停止 → 取回 → 保存JSON/MIDI或回放。最多512项NOTE事件，包含时间、力度与按下/松开；不记录PCM音频。取回约每30ms发送一项，满容量约16秒，须等待全部收齐。断线后重新连接、订阅并取回。

回包12字节，以A6开头，整包异或为0，多字节整数低位在前；F0为命令回执，E0为事件，E1为取回结束。手机回放时序受BLE调度影响。
