# B阶段3已验证整机交付

独立工程源码位于 `standalone/b-stage3-two-timbres/`。
该目录保留B当前已验证的完整版本，避免覆盖C分支根目录的其他集成改动。
打开 `standalone/b-stage3-two-timbres/project/instrument_velocity_32_two_timbres/instrument_velocity_32_two_timbres.gprj`。
工程文件使用相对路径，可在其他电脑打开；芯片GW5AST-LV138PG484AC1/I0，Gowin V1.9.12。

包含钢琴/编钟32声部、24键独立力度阈值与力度频谱/起音、双EC11、滑音、
128ms RAM延迟、实时波形（4倍显示增益）、曲目指引和真实32声部TEST模式。
EC11_B短按依次切换GLIDE、FX、SONG、TEMPO、TEST；长按约0.8秒执行当前页动作。

FSR部分取自C提交 `1cccb07aae52b4c7f29233edaa489203bb82c1c1`：
MCP3008正确SPI时序、无效空位检测、CH0采集、压力滤波映射到全局颤音。
ADC诊断工程、FSR专用显示和C测试未移入独立工程。FSR参数占用三路参数队列的C端口。
标定1/899、死区8；SPI引脚CS=A18、CLK=D15、DIN=D14、DOUT=D16。
原分支根目录中的C诊断工程等仍然保留，仅不参与本独立工程。

本机2026-10-07验证：`tools/verify_velocity.ps1`全部9项通过，包括独立新增
FSR采集到颤音测试、失联撤销与恢复、真实32声部TEST进入/退出，及已有音频回归。
Gowin整机综合完成，Logic77940/138240（报告57%），Register25415，BSRAM34。
仍有位宽和独立PLL时钟关系警告。用户确认FSR版本无问题后要求上传。
源码验证脚本默认XSim位置为E:/vivado2022.2/Vivado/2022.2/bin，队友需按安装路径调整。

不提交.fs、布局布线/综合输出或仿真缓存。下载后需自行运行综合和布局布线，
检查最终时序，再烧录本工程生成的.fs。详细操作参见独立目录README_TWO_TIMBRES.md。
