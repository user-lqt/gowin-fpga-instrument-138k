# 当前版本 V4.9：手势 / 调参 / 虚拟琴键

运行 `main.py`，第三页提供 C4～C5 的 8 个单指琴键，声音由 FPGA 输出。**虚拟琴键需要重新构建并烧录配套 FPGA 工程，旧固件只能调音量/音色。** 已更新当前 `E:/GowinProjects/project` 源码，但本次没有生成新 `.fs`。详见 [部署与测试说明](SINGLE_FILE.md)。

触屏页优先轮询，跳过 AI 通道取帧并按需刷新 UI；支持从空白处滑入音量条。沿用 V4.8.1 放大的按钮、轨道与滑块。

运行同目录 `main.py`。顶部切换「1. 手势控制」「2. 触屏控制」；触屏页提供钢琴/吉他/编钟按钮和 0–100%、5% 一档的音量滑条。已关闭摄像头左右镜像。详见 [单文件部署说明](SINGLE_FILE.md)。触屏页暂停手势推理，切回手势页需收手约 0.6 秒再操作。UART3 和 FPGA 固件无需改动。

# 亚博 CanMV K230 手势与配套屏幕测试

## 推荐部署：单文件联机 V4.7（12 针 GPIO UART3）

将本目录 **main.py** 保存到 K230 `/sdcard/main.py`，即可运行手势识别、屏幕显示和 FPGA 串口控制，并作为开机入口。无需额外复制另外两个项目脚本；保留板上既有亚博系统库和两个手部模型。部署、备份及验证方法见 [SINGLE_FILE.md](SINGLE_FILE.md)。下文 V4.4 为仍保留的分文件维护与测试方式。

V4.6 简化为三种手势：握拳循环切音色／音量页；音色页剪刀手循环钢琴／吉他／编钟；音量页张掌按高度调音量。离散操作后须先放松或离手再触发，短暂漏检不会重复切换。确认过程与执行结果分开显示，并叠加串口发送计数。`gesture_page_control_test.py`、串口模块和单文件版均已更新；下文 V4.4 交互描述为历史参考，以本节和 `SINGLE_FILE.md` 为准。

V4.7 修正实际使用的 K230 接口：12 针排针 **第 5 脚 IO32 TX → FPGA J13-35/C20**，**第 4/7 脚 GND → FPGA GND**。第 3 脚 IO33 RX 只在回环测试时与第 5 脚短接，联机时悬空。旧版 IO9/IO10 UART1 不适用于该排针。

## 历史接口 V4.4

本目录已纳入仓库。克隆后以当前目录运行文件为准，以下 `E:\GowinProjects\k230_gesture_test` 是开发机路径。旧交互脚本和检查作为历史参考保留；当前联机入口为 `gesture_fpga_control.py`。本地 `backups/`、模型、第三方库与重复 FPGA 文件副本不上传。

音色已与最新 FPGA 整合版对齐为 **钢琴 / 吉他 / 编钟（协议编号 0/1/2）**，音量保留 5% 分档和缓慢跟随。直接运行 `gesture_page_control_test.py` 只演示屏幕；联动入口为 `gesture_fpga_control.py`，并需将识别程序和 `k230_fpga_uart.py` 一起复制到板子 `/sdcard/`。接线、FPGA 工程和测试步骤见 [FPGA_UART_WIRING.md](FPGA_UART_WIRING.md)。K230 使用外部 5 V 供电，跨板只接 TX→J13-35/C20 和 GND；蓝牙保留。本次未运行综合或布局布线，旧 `.fs` 不包含该接口。

## 文件

- `gesture_page_control_test.py`：当前交互 V4.4：单指选音量页，张掌按高度调音量，按 5% 一档缓慢跟随；剪刀手选音色页，点赞下一音色、三指上一音色；握拳暂停。仅需两个手部模型，运行方式见 `PALM_HEIGHT_TEST.md`。
- `gesture_fpga_control.py`、`k230_fpga_uart.py`：联机入口与参数协议；`uart_parameter_smoke_test.py`：无需模型的串口参数测试。
- `gesture_music_control_test.py`：捏合调音量、动态左右挥手切换音色编号；单文件屏幕演示，需额外的 `gesture.kmodel`，操作见 `MUSIC_CONTROL_TEST.md`。
- `pinch_screen_test.py`：捏合距离测试，显示拇指/食指距离、相对距离和模拟音量进度条；单文件运行，操作见 `PINCH_TEST.md`。
- `gesture_screen_test.py`：主测试，摄像头画面叠加手掌框、21 个手部关键点、手势名称和 FPS。
- `camera_lcd_test.py`：只验证摄像头和配套屏幕，无需 AI 模型；主测试遇到黑屏或初始化异常时使用。
- `reference/`：此前查询时下载的嘉楠历史参考源码，不需要复制到板子，也不要用它替换亚博配套固件的库。
- `test_control_logic.py`：电脑端纯逻辑检查，不复制到 K230；不执行摄像头或神经网络。
- `test_preprocess_cache.py`：关键点预处理图复用与坐标映射的 2 项电脑端检查。
- `test_static_control_logic.py`：当前高度音量与静态手势的 31 项电脑端逻辑检查；`test_interaction_logic.py`、`test_page_control_logic.py` 保留为运行入口。

本测试按你已下载的亚博例程配置：`lcd`、`640×480`、ST7701 配套屏。当前交互程序使用亚博固件里的 `libs.AIBase`、`libs.AI2D`，并显式建立摄像头与 LCD/IDE 显示管线。本机检查不能替代 K230 实际运行，当前尚未完成上板验证。

## 当前手掌高度交互

在 CanMV IDE 打开 `E:\GowinProjects\k230_gesture_test\gesture_page_control_test.py` 并运行，确认控制台显示 `PALM HEIGHT V4.4`。单指选音量页后张掌保持约 0.4 秒，上移增大音量、下移减小，收起手掌保持。剪刀手选音色页后，点赞/三指切换音色。详细说明见 [PALM_HEIGHT_TEST.md](PALM_HEIGHT_TEST.md)。直接运行此文件只演示屏幕；联机请用 `gesture_fpga_control.py`，参照接口文档。

## 单独测试手势分类（gesture_screen_test.py）

1. K230 装好摄像头、配套屏幕和带配套固件的 TF 卡，用 USB 数据线连接电脑。
2. 在 CanMV IDE 左下角点击连接，选择 K230 对应端口。连接会打断原有开机程序，屏幕暂时黑屏属于正常现象。
3. 使用 **文件 → 打开文件**，打开电脑上的 `E:\GowinProjects\k230_gesture_test\gesture_screen_test.py`。
4. 点击 IDE 左下角绿色运行按钮。程序在 K230 上执行，LCD 显示摄像头画面和识别结果。
5. 将一只手完整放在镜头内，先依次做张掌、握拳、剪刀手，每个动作保持约 1 秒。距离以手掌能完整入镜、画面清晰为准。
6. 点击停止按钮退出。先用 IDE 临时运行，不必覆盖板子现有的 `main.py`。

如果需要先确认摄像头和屏幕，按相同方法运行 `camera_lcd_test.py`。应显示实时画面及绿色的 `K230 CAMERA / LCD OK`。

## 应看到什么

- 无手：`NO HAND 未检测到手`。
- 检测到手：绿色手掌框、彩色骨架、白色关键点。
- 动作稳定：连续 3 帧相同后显示绿色手势名称；变化过程中显示 `WAIT 请保持手势`。
- 有手但角度不符合规则：`UNKNOWN 未识别`，并不代表程序停止。
- 手离开画面：立即清除上一次手势，恢复 `NO HAND`。
- 只处理画面中面积最大的手；请先用单手测试。

| 显示名称 | 动作 |
|---|---|
| FIVE 张掌 | 五指张开 |
| FIST 握拳 | 五指收拢 |
| YEAH 剪刀手 | 食指、中指伸直，其他手指收拢 |
| ONE 数字一 | 食指伸直，其他手指收拢 |
| SIX 数字六 | 拇指、小指伸直，其他手指收拢 |
| THREE 数字三 | 食指、中指、无名指伸直，拇指和小指收拢 |
| THUMB UP 竖拇指 | 拇指伸直，其他手指收拢 |
| GUN 手枪 | 拇指、食指伸直，其他手指收拢 |
| LOVE 手势 | 拇指、食指、小指伸直，中指和无名指收拢 |

静态手势沿用亚博例程的角度规则；手背朝向、遮挡和侧转可能导致未识别。此处没有实现挥手等动态手势。

## 模型与固件

需要配套的两个模型：

```text
/sdcard/kmodel/hand_det.kmodel
/sdcard/kmodel/handkp_det.kmodel
```

程序还会查找 `/sdcard/examples/kmodel` 和 `/sdcard/app/tests/kmodel`。两个模型需位于同一目录。若模型放在别处，修改主程序顶部 `MODEL_DIR` 为板端目录。

这些路径是 **K230 TF 卡内路径**，电脑上的 `D:`、`E:` 路径不能直接填写进去。

目前下载的资料目录里有手势 Python 源码和 `CanMV_K230_YAHBOOM_micropython_V1.4.3-3.img.gz`，没有找到这两个独立的手势模型文件。它们可能已随板载出厂固件提供；主程序启动会检查文件并打印实际路径。如果报 `Missing hand_det.kmodel / handkp_det.kmodel`，检查板子 TF 卡上的 `kmodel` 目录，使用亚博与固件匹配的模型资源。安装 IDE 本身不会安装板端模型和固件。

不要为了运行本测试直接重烧已有 TF 卡；先检查文件和固件版本。

## 常见报错

| 现象 | 检查方法 |
|---|---|
| `ImportError: ... libs` | 检查是否使用亚博配套固件、TF 卡是否挂载，及板端 `libs` 目录；不要在电脑 CPython 中运行。 |
| 模型不存在 | 查看控制台的 `Checked` 目录，检查 TF 卡模型位置或修改 `MODEL_DIR`。 |
| 模型加载或推理报错 | 核对模型与板端 nncase 运行库版本，保留 `FAILED at:` 和完整报错。 |
| 黑屏或摄像头初始化失败 | 先停止主测试，再运行 `camera_lcd_test.py`；断电后核对排线，再上电。 |
| 连续运行后内存不足 | 停止后再运行；若前一个程序未释放资源，重新给 K230 上电。 |
| 有画面、没有手掌框 | 保持单手完整入镜，避免逆光或遮挡；先测试张掌。 |

## 相对原例程的修改

- 将关键点绘制循环改为整数索引，避免 `range(len(points)/2)` 的浮点参数错误。
- 修正关键点映射时裁剪框宽高互换的问题，手靠近边缘时非正方形裁剪也使用正确比例。
- 对角度计算增加零向量和余弦范围检查，无效关键点不误判为张掌。
- 增加连续帧确认、无手提示、FPS 和初始化阶段报错。
- 清理代码放进 `finally`，停止及异常时释放已经创建的模型和显示管线。

## 来源

- 本地亚博配套源码：`D:\K230_ZiLiao\K230视觉模块\程序源码\08.Body\07.hand_keypoint_class.py`
- 本地摄像头例程：`D:\K230_ZiLiao\K230视觉模块\程序源码\02.Basic\17.sensor.py`
- [亚博手掌关键点分类教程](https://www.yahboom.com/build?id=13291&cid=705)
- [嘉楠 AI Demo 说明](https://www.kendryte.com/k230_canmv/zh/main/example/ai/ai_demo_user_manual.html)
