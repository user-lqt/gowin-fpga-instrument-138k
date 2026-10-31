"""Build the one-file K230 deployment from the maintained UI and UART sources."""
import ast
from pathlib import Path


ROOT = Path(__file__).resolve().parent


def module_body(filename):
    source = (ROOT / filename).read_text(encoding="utf-8")
    tree = ast.parse(source)
    doc = tree.body[0]
    if not isinstance(doc, ast.Expr) or not isinstance(doc.value, ast.Constant):
        raise ValueError("Expected module documentation in " + filename)
    return "\n".join(source.splitlines()[doc.end_lineno:]).strip()


def build():
    ui = module_body("gesture_page_control_test.py")
    footer = 'if __name__ == "__main__":\n    main()'
    if not ui.endswith(footer):
        raise ValueError("Screen entry point changed; review the single-file launcher")
    ui = ui[:-len(footer)].rstrip()
    ui = ui.replace('"STATE pose", control.pose,',
                    '"STATE UART_TX", fpga_link.sent_commands if fpga_link is not None else 0,\n'
                    '                      "pose", control.pose,')
    uart = module_body("k230_fpga_uart.py")
    marker = "class HandDetector(AIBase):"
    if ui.count(marker) != 1:
        raise ValueError("Cannot locate the UART insertion point")
    ui = ui.replace(marker, uart + "\n\n\n" + marker, 1)
    header = '''# -*- coding: utf-8 -*-
"""亚博 K230 手势控制 FPGA，单文件部署 V4.9，12 针 GPIO UART3。

将本文件保存为 /sdcard/main.py，或在 CanMV IDE 直接运行。
包含手势/调参/琴键三页面、透明屏幕显示和 UART 发送；无需另外两个项目脚本。
沿用板上亚博系统库及 /sdcard/kmodel/ 内两个手部识别模型。
启动不覆盖 FPGA 参数，只有实际调整时发送；UART_TX 不是接收确认。
由 build_single_file.py 生成，维护源文件后重新生成。
"""
'''
    launcher = '''


def run():
    print("K230 FPGA SINGLE FILE V4.9 UART3")
    print("K230 UART3: 115200 8N1; header pin 5 IO32 TX -> FPGA J13-35/C20")
    print("Header pin 3 IO33 RX unused; pin 4/7 GND -> FPGA GND")
    print("Page 3 virtual keys require the updated FPGA receiver/top and a NEW bitstream.")
    print("UART_TX is not an FPGA ACK. Keys: NOTE_ON/OFF, B6 lease heartbeat.")
    link = FpgaLink()
    try:
        main(fpga_link=link)
    finally:
        link.deinit()


if __name__ == "__main__":
    run()
'''
    output = header + ui + launcher
    ast.parse(output)
    (ROOT / "main.py").write_text(output, encoding="utf-8", newline="\n")
    return output


if __name__ == "__main__":
    build()
    print("Built", ROOT / "main.py")
