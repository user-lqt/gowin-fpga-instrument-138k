# K230控制程序

`main.py` 为当前单文件V4.9程序，包含手势、调参、8个虚拟琴键页面。
需要板上亚博系统的 `libs.AIBase`、`libs.AI2D` 等接口和兼容摄像头/屏幕固件，普通桌面Python不能运行摄像头主程序。

模型不在本包内：板上需合法安装 `hand_det.kmodel` 和 `handkp_det.kmodel`，优先路径 `/sdcard/kmodel/`；程序也搜索源码所列其他模型目录。
部署前保留板上原main.py，复制本目录main.py到实际启动位置。

当前UART3为115200、8N1：12针GPIO排针pin5（IO32 TX）接FPGA J13-35/C20，GND接共同地；IO33为RX映射但本协议不依赖接收确认。接线前仍需核对实际开发板版本和FPGA约束，不能混用厂商另一组UART1接口。

启动不主动覆盖FPGA参数，实际调参才发送。屏幕UART_TX计数只证明程序尝试发送，不是FPGA ACK。
协议/触摸/控制辅助Python文件及主机测试保留，便于维护；模型、第三方运行库不冒充本项目源码。
