# 下载与交接

1. 先运行根目录的SHA256校验，或用 `Get-FileHash bitstream/integrated_instrument_64.fs -Algorithm SHA256` 对照README。
2. 使用与本工程匹配的开发板和电平；以 `project/integrated_instrument_64/source` 下的实际CST约束及 `reports/pinout.html` 为准，不凭接口名称猜引脚。
3. 打开Gowin Programmer，检测JTAG链，确认器件为GW5AST-138C对应的GW5AST-LV138PG484AC1/I0，选择本包64版FS。
4. 如选择SRAM下载，断电会丢失；需上电保留时，按实际开发板Flash型号及厂商流程选择受支持的Flash编程方式。本包不假定外置Flash型号或自动设置擦写操作。
5. 检查下载成功后六页切换、键盘、音色、颤音、双声道及TEST；记录烧录文件SHA，不混用旧文件。

现场验证建议：

- 测量PCM5102A的LCK/LRCK/WS时钟，目标48kHz。这里是左右声道字选择时钟，不是BCK，也不是音频信号引脚。
- 外部采集DAC模拟输出验证ALL64、GROUP16、MUTE63及恢复ALL，逐路核对目标峰消失，不能仅看屏幕ACTIVE数字。
- 音频核心共享算术但保存64路独立状态；谐波、左右声道、效果器和DSP单元不另计为振荡器。
- 重新测量按键至DAC模拟起音延迟，不因15帧参数直接宣称小于5ms。
- 本包未自动烧录，也没有新增现场测量记录。

PC软件依赖Python3、Tkinter、NumPy和Matplotlib。通过系统声卡采集模拟DAC输出，不是从FPGA内部自动读回；音频接口电平和接地应按实际硬件安排，避免过载。原测量记录未随本包改写。
