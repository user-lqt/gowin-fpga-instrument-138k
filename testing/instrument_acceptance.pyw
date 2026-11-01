"""Unified desktop launcher without a terminal window."""

from pathlib import Path
import sys
import traceback
import tkinter as tk
from tkinter import messagebox

sys.path.insert(0, str(Path(__file__).resolve().parent / "tools"))
try:
    from instrument_acceptance_gui import main
    main()
except Exception:
    root = tk.Tk()
    root.withdraw()
    messagebox.showerror("测量与验收程序启动失败", traceback.format_exc())
    root.destroy()
