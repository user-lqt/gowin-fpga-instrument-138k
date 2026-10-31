# -*- coding: utf-8 -*-
"""亚博 K230 摄像头与配套屏幕检查，不依赖 AI 模型。"""
import os
import sys
import gc
import time
from media.sensor import Sensor
from media.display import Display
from media.media import MediaManager

sensor = None
try:
    os.exitpoint(os.EXITPOINT_ENABLE)
    sensor = Sensor()
    sensor.reset()
    sensor.set_framesize(width=640, height=480)
    sensor.set_pixformat(Sensor.RGB565)
    Display.init(Display.ST7701, width=640, height=480, to_ide=True)
    MediaManager.init()
    sensor.run()
    clock = time.clock()
    while True:
        os.exitpoint()
        clock.tick()
        frame = sensor.snapshot()
        frame.draw_string_advanced(10, 10, 24, "K230 CAMERA / LCD OK", color=(0, 255, 0))
        Display.show_image(frame)
        del frame
        gc.collect()
        time.sleep_ms(5)
except KeyboardInterrupt:
    print("Stopped by user.")
except Exception as error:
    sys.print_exception(error)
    raise
finally:
    # 分别清理，避免一个资源停止失败阻止后续释放。
    if sensor is not None:
        try:
            sensor.stop()
        except Exception as error:
            print("Cleanup sensor:", error)
    try:
        Display.deinit()
    finally:
        os.exitpoint(os.EXITPOINT_ENABLE_SLEEP)
        time.sleep_ms(100)
        MediaManager.deinit()
