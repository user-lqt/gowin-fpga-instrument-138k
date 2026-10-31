"""Verify every deployed entry actually configures the user's 12-pin UART3."""
import ast
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from k230_fpga_uart import FpgaLink
from test_single_file import load_single_file


class HeaderTests(unittest.TestCase):
    def setUp(self):
        self.pins, self.ports, self.frames, self.closed = [], [], [], []
        self.write_result = None
        owner = self
        class FPIOA:
            UART3_TXD, UART3_RXD = 'UART3_TXD', 'UART3_RXD'
            def set_function(self, pin, function, **options):
                owner.pins.append((pin, function, options))
        class UART:
            UART3 = 3
            def __init__(self, port, baud):
                owner.ports.append((port, baud))
                self.buffer = b''
            def write(self, data):
                owner.frames.append(data)
                self.buffer = data
                return len(data) if owner.write_result is None else owner.write_result
            def read(self, size):
                result, self.buffer = self.buffer, b''
                return result
            def any(self): return len(self.buffer)
            def deinit(self): owner.closed.append(True)
        self.machine = SimpleNamespace(UART=UART, FPIOA=FPIOA)

    def assert_header(self):
        self.assertEqual(self.ports, [(3, 115200)])
        self.assertEqual(self.pins, [
            (32, 'UART3_TXD', dict(ie=0, oe=1, pu=1)),
            (33, 'UART3_RXD', dict(ie=1, oe=0, pu=1))])

    def check_link(self, constructor):
        with patch.dict(sys.modules, machine=self.machine):
            link = constructor()
        self.assert_header()
        self.assertEqual(link.send(0xB5, 1), bytes.fromhex('A5 B5 01 00 11'))
        self.write_result = 0
        with self.assertRaises(OSError):
            link.send(0xB4, 25)
        self.assertEqual(link.sent_commands, 1)
        link.deinit()
        self.assertEqual(self.closed, [True])

    def test_maintained_link_uses_gpio_header(self):
        self.check_link(FpgaLink)

    def test_single_file_link_uses_gpio_header(self):
        self.check_link(load_single_file()['FpgaLink'])

    def check_diagnostic(self, filename, frame_count):
        tree = ast.parse(Path(__file__).with_name(filename).read_text(encoding='utf-8'))
        functions = [n for n in tree.body if isinstance(n, ast.FunctionDef)]
        logs = []
        namespace = dict(UART=self.machine.UART, FPIOA=self.machine.FPIOA,
                         time=SimpleNamespace(sleep_ms=lambda ms: None,
                                              ticks_ms=lambda: 0, ticks_diff=lambda a,b: a-b),
                         print=lambda *args: logs.append(' '.join(map(str,args))))
        exec(compile(ast.Module(body=functions, type_ignores=[]), filename, 'exec'), namespace)
        namespace['main']()
        self.assert_header()
        self.assertEqual(len(self.frames), frame_count)
        self.assertEqual(self.closed, [True])
        return logs

    def test_fixed_commands_use_gpio_header(self):
        self.check_diagnostic('uart_link_diagnostic.py', 8)
        self.assertEqual(self.frames[0], bytes.fromhex('A5 B4 00 00 11'))

    def test_loopback_uses_gpio_header(self):
        self.assertIn('RESULT: 10/10 PASS', self.check_diagnostic('uart_loopback_test.py', 10))


if __name__ == '__main__':
    unittest.main()
