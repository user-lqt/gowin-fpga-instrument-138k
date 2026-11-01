"""Selected oscillator counts remain distinct from software verification."""

from pathlib import Path
from types import SimpleNamespace
import tkinter as tk
from tkinter import ttk
import unittest
from unittest.mock import patch

from acceptance_extra_pages import EvidencePage


class EvidencePageTests(unittest.TestCase):
    def setUp(self):
        self.root = tk.Tk()
        self.root.withdraw()
        self.page = EvidencePage(self.root, SimpleNamespace(any_busy=lambda: False))

    def tearDown(self):
        self.root.after_cancel(self.page.poll_id)
        self.root.destroy()

    def test_selectable_oscillator_count(self):
        def walk(widget):
            for child in widget.winfo_children():
                yield child
                yield from walk(child)
        widgets = list(walk(self.page.page))
        self.assertTrue(any(isinstance(w, ttk.Spinbox) for w in widgets))
        self.assertEqual(self.page.count.get(), "64")
        table = next(w for w in widgets if isinstance(w, ttk.Treeview))
        values = str([table.item(i, "values") for i in table.get_children()])
        self.assertIn("技术文档佐证", values)
        self.assertIn("吞吐量计算", values)
        self.assertFalse(self.page.count_verified.get())
        self.assertTrue(any(isinstance(w, ttk.Checkbutton) for w in widgets))

    def test_generate_passes_only_two_records_and_output(self):
        self.page.lrck.set("lrck-record")
        self.page.poly.set("poly-record")
        with patch("acceptance_extra_pages.next_folder", return_value=Path("output")), \
                patch("acceptance_evidence.generate", return_value=Path("report.html")) as generate, \
                patch.object(self.page, "run", side_effect=lambda worker: worker()):
            self.page.generate()
        generate.assert_called_once_with(
            "lrck-record", "poly-record", Path("output"),
            declared_count=64, count_user_verified=False)

    def test_human_verification_is_explicit_and_scoped_to_records_and_count(self):
        self.page.lrck.set("lrck-record")
        self.page.poly.set("poly-record")
        self.page.count_verified.set(True)
        with patch("acceptance_extra_pages.next_folder", return_value=Path("output")), \
                patch("acceptance_evidence.generate", return_value=Path("report.html")) as generate, \
                patch.object(self.page, "run", side_effect=lambda worker: worker()):
            self.page.generate()
        generate.assert_called_once_with(
            "lrck-record", "poly-record", Path("output"),
            declared_count=64, count_user_verified=True)
        for variable, value in ((self.page.count, "32"), (self.page.lrck, "other-lrck"),
                                (self.page.poly, "other-poly")):
            self.page.count_verified.set(True)
            variable.set(value)
            self.assertFalse(self.page.count_verified.get())

    def test_worker_keeps_confirmation_from_button_click(self):
        self.page.lrck.set("lrck-record")
        self.page.poly.set("poly-record")
        self.page.count_verified.set(True)
        with patch.object(self.page, "run") as run:
            self.page.generate()
        worker = run.call_args.args[0]
        self.page.count.set("32")
        with patch("acceptance_extra_pages.next_folder", return_value=Path("output")), \
                patch("acceptance_evidence.generate", return_value=Path("report.html")) as generate:
            worker()
        generate.assert_called_once_with(
            "lrck-record", "poly-record", Path("output"),
            declared_count=64, count_user_verified=True)

    def test_invalid_count_does_not_start_worker(self):
        self.page.lrck.set("lrck-record")
        self.page.poly.set("poly-record")
        for value in ("0", "4097", "1.5", "abc"):
            self.page.count.set(value)
            with self.subTest(value=value), patch("acceptance_extra_pages.messagebox.showerror") as error, \
                    patch.object(self.page, "run") as run:
                self.page.generate()
                error.assert_called_once()
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
