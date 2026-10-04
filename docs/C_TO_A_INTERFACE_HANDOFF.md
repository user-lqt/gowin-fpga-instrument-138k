# C -> A 接口交接单

日期：2026-09-25

进度：A 的 `5158e5b` 已实现两个溢出端口和事件溢出静音恢复；C 独立联调通过。测试台声明顺序已在 `afc7a89` 修复并推送，ModelSim 回归 46/46 通过。下述条目保留为接口验收依据。

## A 需要修改的接口

在 `audio_core` 的现有端口末尾增加：

```verilog
output wire event_overflow,
output wire param_overflow
```

端口名称必须与 `rtl/common/event_defs.vh` 和 `docs/INTERFACE_FREEZE.md` 一致。两个信号均为高有效、粘滞状态，`rst_n=0` 时清零。

`overload_flag` 继续只表示音频削波，不能复用为输入队列溢出。

## 事件溢出行为

当事件 FIFO 已满且 `event_valid=1` 不能接收时：

1. 置位 `event_overflow`；
2. 清空事件 FIFO；
3. 关闭当前音符/声部，音频输出回到静音；
4. 拒收后续事件，直到复位。

这样可以避免 NOTE_OFF 丢失后持续发声。参数 FIFO 溢出只置位 `param_overflow`，已接受的参数按顺序继续应用，不要求关闭音频。

## 输入时序

- `event_valid` 或 `param_valid` 每个时钟上升沿为高，都代表一个新条目。
- 连续多个周期为高时，载荷可以逐拍变化；不能只检测 `valid` 的上升沿。
- A 与 B 第一版联调使用同一个 `clk_audio`。若改成跨时钟连接，C 会另做完整的载荷 CDC。
- A1 每个 `sample_tick` 最多消费一个事件和一个参数；队列深度目前分别为 16 和 4。

## A 必须补充的测试

- 连续 16 个时钟周期的 `event_valid`，确认 16 项按序入队。
- 队列满时同拍出队、入队，计数保持 16。
- 第 17 个事件为 NOTE_OFF 时，确认 `event_overflow=1`、队列清空、声部静音。
- 参数连续输入 5 项时，确认第 5 项被拒绝但前 4 项按序应用，`param_overflow=1`。
- 复位后两个溢出状态、FIFO、当前声部均清零。
- 测试台每个 `sample_tick` 只产生一个采样边沿，不使用会造成额外消费的 `force/release` 节拍方式。

## C 侧接入条件

C 将把：

```verilog
system_error = event_overflow || param_overflow
    ? ERR_INPUT_QUEUE_OVERFLOW : 8'h00;
system_ready = audio_locked && engine_ready && !event_overflow;
```

接入系统状态。事件溢出会拉低 `system_ready`，通过 B 的 `run_reset_n` 让输入端停止并等待整机复位；参数溢出保持 `system_ready`，只显示故障。

完成以上端口和测试后，A 把提交交给 C 做 B -> A -> I2S 联调。C 当前已完成 `system_status` 和 C/B 启动顺序测试。
