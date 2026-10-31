# -*- coding: utf-8 -*-
"""亚博 CanMV K230：显示拇指/食指捏合距离及模拟音量。

在 CanMV IDE 中直接打开本文件运行。单文件，无需 gesture_screen_test.py。
使用亚博配套固件、libs 和手部模型；本程序不发送串口数据，不输出音频。
"""

import os
import sys
import time
import math
import gc

for lib_root in ("/sdcard", "/sdcard/app"):
    if lib_root not in sys.path:
        sys.path.append(lib_root)

from libs.PipeLine import PipeLine
from libs.AIBase import AIBase
from libs.AI2D import Ai2d
import nncase_runtime as nn
import ulab.numpy as np
import aicube


DISPLAY_SIZE = [640, 480]
CAMERA_SIZE = [640, 480]
MODEL_DIR = ""  # 留空自动查找；修改时填板端目录，例如 /sdcard/kmodel。
MODEL_DIRS = ("/sdcard/kmodel", "/sdcard/examples/kmodel", "/sdcard/app/tests/kmodel")
CONFIDENCE = 0.20
ANCHORS = [26, 27, 53, 52, 75, 71, 80, 99, 106, 82,
           99, 134, 140, 113, 161, 172, 245, 276]

# 比例 = 拇指尖(4)到食指尖(8)的距离 / 手腕(0)到中指根部(9)的距离。
# 下列是首次测试用估计值，不是实测标定。依据屏幕显示的“相对距离”调整。
CLOSE_RATIO = 0.15     # 小于等于此比例：模拟音量 0%。
OPEN_RATIO = 1.60      # 扩大调节行程；大于等于此比例：模拟音量 100%。
MIN_PALM_PIXELS = 15.0 # 手太小或参考点重合时不输出距离/音量。
SMOOTH_TIME_MS = 350.0 # 音量平滑时间；像素距离、相对距离保留实时读数。
VOLUME_DEADBAND = 3.0  # 目标音量变化不足 3 个百分点时忽略，减少手指微抖。
MAX_RATE_PER_SECOND = 35.0 # 每秒最多变化 35 个百分点；0 表示取消限速。
MAX_STEP_MS = 150.0    # 避免偶发长帧或暂停后一次跳变过大。


def measure_pinch(points, size=CAMERA_SIZE):
    """返回 (像素距离, 相对距离, 手掌像素长度) 或 None，不假定真实毫米长度。"""
    if points is None or len(points) != 42:
        return None
    coords = []
    for index in (0, 4, 8, 9):
        x, y = float(points[index * 2]), float(points[index * 2 + 1])
        if not math.isfinite(x) or not math.isfinite(y):
            return None
        if x < 0 or y < 0 or x >= size[0] or y >= size[1]:
            return None
        coords.append((x, y))
    wrist, thumb, index_tip, middle_base = coords
    palm = math.sqrt((wrist[0] - middle_base[0]) ** 2 + (wrist[1] - middle_base[1]) ** 2)
    if palm < MIN_PALM_PIXELS:
        return None
    distance = math.sqrt((thumb[0] - index_tip[0]) ** 2 + (thumb[1] - index_tip[1]) ** 2)
    return distance, distance / palm, palm


class PinchControl:
    """把有效几何测量映射为模拟音量，丢失时清除平滑历史。"""
    def __init__(self, close_ratio=CLOSE_RATIO, open_ratio=OPEN_RATIO,
                 smooth_ms=SMOOTH_TIME_MS, deadband=VOLUME_DEADBAND,
                 max_rate=MAX_RATE_PER_SECOND):
        if not (math.isfinite(close_ratio) and math.isfinite(open_ratio)
                and 0 <= close_ratio < open_ratio):
            raise ValueError("Require 0 <= CLOSE_RATIO < OPEN_RATIO")
        if not math.isfinite(smooth_ms) or smooth_ms < 0:
            raise ValueError("SMOOTH_TIME_MS must be >= 0")
        if not math.isfinite(deadband) or not 0 <= deadband < 100:
            raise ValueError("VOLUME_DEADBAND must be in [0, 100)")
        if not math.isfinite(max_rate) or max_rate < 0:
            raise ValueError("MAX_RATE_PER_SECOND must be >= 0")
        self.close_ratio = close_ratio
        self.open_ratio = open_ratio
        self.smooth_ms = smooth_ms
        self.deadband = deadband
        self.max_rate = max_rate
        self.percent = None
        self.accepted_target = None

    def reset(self):
        self.percent = None
        self.accepted_target = None

    def update(self, points, elapsed_ms):
        measurement = measure_pinch(points)
        if measurement is None:
            self.reset()
            return None
        distance, ratio, palm = measurement
        target = 100.0 * (ratio - self.close_ratio) / (self.open_ratio - self.close_ratio)
        target = max(0.0, min(100.0, target))
        # 死区作用于上次接受的目标，不会让平滑结果一直追着测量噪声跑。
        if (self.accepted_target is None or target == 0 or target == 100
                or abs(target - self.accepted_target) >= self.deadband):
            self.accepted_target = target
        if self.percent is None:
            # 首次入镜直接显示当前姿势；后续调节才使用平滑和限速。
            self.percent = target
        else:
            elapsed_ms = max(0.0, min(MAX_STEP_MS, float(elapsed_ms)))
            alpha = 1.0 if self.smooth_ms == 0 else 1.0 - math.exp(-elapsed_ms / self.smooth_ms)
            step = alpha * (self.accepted_target - self.percent)
            if self.max_rate > 0:
                limit = self.max_rate * elapsed_ms / 1000.0
                step = max(-limit, min(limit, step))
            self.percent = max(0.0, min(100.0, self.percent + step))
        return {"distance_px": distance, "ratio": ratio, "palm_px": palm,
                "target_percent": target, "percent": int(self.percent + 0.5)}


def find_models():
    directories = (MODEL_DIR,) if MODEL_DIR else MODEL_DIRS
    for directory in directories:
        paths = (directory + "/hand_det.kmodel", directory + "/handkp_det.kmodel")
        try:
            if all(os.stat(path)[6] > 0 for path in paths):
                return paths
        except OSError:
            pass
    raise RuntimeError("Missing hand_det.kmodel / handkp_det.kmodel. Checked: "
                       + str(directories) + ". Use matching Yahboom models.")


class HandDetector(AIBase):
    # 模型输入、锚框、填充颜色沿用亚博配套手掌检测例程。
    def __init__(self, path):
        super().__init__(path, [512, 512], CAMERA_SIZE, 0)
        self.ai2d = Ai2d(0)
        self.ai2d.set_ai2d_dtype(nn.ai2d_format.NCHW_FMT, nn.ai2d_format.NCHW_FMT,
                                np.uint8, np.uint8)

    def config_preprocess(self):
        w, h = CAMERA_SIZE
        ratio = min(512.0 / w, 512.0 / h)
        dw, dh = (512 - int(w * ratio)) / 2, (512 - int(h * ratio)) / 2
        self.ai2d.pad([0, 0, 0, 0, int(round(dh - 0.1)), int(round(dh + 0.1)),
                       int(round(dw - 0.1)), int(round(dw + 0.1))], 0, [114, 114, 114])
        self.ai2d.resize(nn.interp_method.tf_bilinear, nn.interp_mode.half_pixel)
        self.ai2d.build([1, 3, h, w], [1, 3, 512, 512])

    def postprocess(self, results):
        return aicube.anchorbasedet_post_process(
            results[0], results[1], results[2], [512, 512], CAMERA_SIZE,
            [8, 16, 32], 1, CONFIDENCE, 0.5, ANCHORS, False)


class HandKeypoints(AIBase):
    def __init__(self, path):
        super().__init__(path, [256, 256], CAMERA_SIZE, 0)
        self.crop = None
        self.ai2d = Ai2d(0)
        self.ai2d.set_ai2d_dtype(nn.ai2d_format.NCHW_FMT, nn.ai2d_format.NCHW_FMT,
                                np.uint8, np.uint8)

    def config_preprocess(self, box):
        x1, y1, x2, y2 = [float(value) for value in box[2:6]]
        cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
        half = 1.26 * max(x2 - x1, y2 - y1) / 2
        left = max(0, min(CAMERA_SIZE[0] - 1, int(cx - half)))
        top = max(0, min(CAMERA_SIZE[1] - 1, int(cy - half)))
        right = max(left, min(CAMERA_SIZE[0] - 1, int(cx + half)))
        bottom = max(top, min(CAMERA_SIZE[1] - 1, int(cy + half)))
        self.crop = [left, top, right - left + 1, bottom - top + 1]
        self.ai2d.crop(*self.crop)
        self.ai2d.resize(nn.interp_method.tf_bilinear, nn.interp_mode.half_pixel)
        self.ai2d.build([1, 3, CAMERA_SIZE[1], CAMERA_SIZE[0]], [1, 3, 256, 256])

    def postprocess(self, results):
        values = results[0].reshape((42,))
        x, y, width, height = self.crop
        points = []
        for index in range(21):
            px, py = float(values[index * 2]), float(values[index * 2 + 1])
            if not math.isfinite(px) or not math.isfinite(py):
                return None
            points.extend((px * width + x, py * height + y))
        return points


def choose_hand(boxes):
    best, best_area = None, 0
    for box in boxes:
        x1, y1, x2, y2 = [float(value) for value in box[2:6]]
        if not all(math.isfinite(value) for value in (x1, y1, x2, y2)):
            continue
        width, height = x2 - x1, y2 - y1
        if width < 20 or height < CAMERA_SIZE[1] * 0.1:
            continue
        if x2 <= 0 or y2 <= 0 or x1 >= CAMERA_SIZE[0] or y1 >= CAMERA_SIZE[1]:
            continue
        area = width * height
        if area > best_area:
            best, best_area = box, area
    return best


def screen_xy(x, y, size):
    return (max(0, min(size[0] - 1, int(x * size[0] / CAMERA_SIZE[0]))),
            max(0, min(size[1] - 1, int(y * size[1] / CAMERA_SIZE[1]))))


def draw_frame(pl, box, points, reading, fps):
    canvas = pl.osd_img
    canvas.clear()
    width, height = pl.display_size
    white, yellow, green = (255, 255, 255, 255), (255, 255, 220, 0), (255, 0, 255, 130)
    if box is not None:
        x1, y1 = screen_xy(float(box[2]), float(box[3]), pl.display_size)
        x2, y2 = screen_xy(float(box[4]), float(box[5]), pl.display_size)
        canvas.draw_rectangle(x1, y1, max(1, x2 - x1), max(1, y2 - y1),
                              color=green, thickness=2)
    if points is not None:
        coords = [screen_xy(points[2 * i], points[2 * i + 1], pl.display_size) for i in range(21)]
        for finger in range(5):
            previous = 0
            for joint in range(1 + finger * 4, 5 + finger * 4):
                canvas.draw_line(coords[previous][0], coords[previous][1],
                                 coords[joint][0], coords[joint][1],
                                 color=(255, 120, 170, 210), thickness=1)
                previous = joint
        for x, y in coords:
            canvas.draw_circle(x, y, 2, color=white, fill=True)
        if reading is not None:
            thumb, index_tip = coords[4], coords[8]
            canvas.draw_line(thumb[0], thumb[1], index_tip[0], index_tip[1],
                             color=yellow, thickness=4)
            for x, y in (thumb, index_tip):
                canvas.draw_circle(x, y, 7, color=yellow, fill=True)
            label_x = max(5, min(width - 110, (thumb[0] + index_tip[0]) // 2))
            label_y = max(116, min(height - 150, (thumb[1] + index_tip[1]) // 2 - 25))
            canvas.draw_rectangle(label_x, label_y, 106, 24, color=(255, 15, 20, 30), fill=True)
            canvas.draw_string_advanced(label_x + 3, label_y + 1, 20,
                                        "%.1f px" % reading["distance_px"], color=yellow)

    canvas.draw_rectangle(0, 0, width, 108, color=(255, 15, 20, 30), fill=True)
    canvas.draw_string_advanced(10, 5, 24, "K230 捏合距离测试", color=white)
    canvas.draw_string_advanced(width - 150, 8, 20, "FPS: %.1f" % fps, color=white)
    if reading is None:
        distance_text = "指尖距离: -- px"
        ratio_text = "相对距离: --"
        volume_text = "模拟音量: --%"
        status = "未检测到手" if box is None else "请完整展示手掌"
    else:
        distance_text = "指尖距离: %.1f px" % reading["distance_px"]
        ratio_text = "相对距离: %.2f  (手掌长度=1)" % reading["ratio"]
        volume_text = "模拟音量: %d%%" % reading["percent"]
        status = "手指靠拢" if reading["ratio"] <= CLOSE_RATIO else (
            "手指张开" if reading["ratio"] >= OPEN_RATIO else "调节中")
    canvas.draw_string_advanced(10, 36, 28, distance_text, color=yellow)
    canvas.draw_string_advanced(10, 73, 22, ratio_text, color=white)
    panel_y = height - 118
    canvas.draw_rectangle(0, panel_y, width, 118, color=(255, 15, 20, 30), fill=True)
    canvas.draw_string_advanced(12, panel_y + 6, 30, volume_text, color=green)
    canvas.draw_string_advanced(width - 210, panel_y + 12, 22, status, color=yellow)
    bar_x, bar_y, bar_width = 16, panel_y + 50, width - 32
    canvas.draw_rectangle(bar_x, bar_y, bar_width, 24, color=white, thickness=2)
    if reading is not None:
        fill_width = (bar_width - 6) * reading["percent"] // 100
        if fill_width > 0:
            canvas.draw_rectangle(bar_x + 3, bar_y + 3, fill_width, 18, color=green, fill=True)
    canvas.draw_string_advanced(12, height - 30, 20, "靠拢减小 / 张开增大 / 单手完整入镜", color=white)


def release(name, obj):
    if obj is not None:
        try:
            obj.deinit()
        except Exception as error:
            print("Cleanup", name, error)


def main():
    pl, detector, keypoints = None, None, None
    stage = "check settings and model files"
    try:
        os.exitpoint(os.EXITPOINT_ENABLE)
        control = PinchControl()
        det_path, kp_path = find_models()
        print("Hand detector:", det_path)
        print("Hand keypoints:", kp_path)
        print("Pinch ratio endpoints:", CLOSE_RATIO, OPEN_RATIO)
        stage = "create camera and LCD"
        pl = PipeLine(rgb888p_size=CAMERA_SIZE, display_size=DISPLAY_SIZE, display_mode="lcd")
        pl.create()
        draw_frame(pl, None, None, None, 0)
        pl.show_image()
        stage = "load hand detector"
        detector = HandDetector(det_path)
        detector.config_preprocess()
        stage = "load hand keypoints"
        keypoints = HandKeypoints(kp_path)
        clock = time.clock()
        previous_ms = time.ticks_ms()
        last_log_ms = previous_ms
        stage = "pinch loop"
        print("Ready. Bring thumb and index fingertips together, then open them.")
        while True:
            os.exitpoint()
            clock.tick()
            frame = pl.get_frame()
            box = choose_hand(detector.run(frame))
            points = None
            if box is not None:
                keypoints.config_preprocess(box)
                points = keypoints.run(frame)
            now_ms = time.ticks_ms()
            reading = control.update(points, time.ticks_diff(now_ms, previous_ms))
            previous_ms = now_ms
            draw_frame(pl, box, points, reading, clock.fps())
            pl.show_image()
            # 约每 500ms 输出一次，便于首次调整范围，避免逐帧打印拖慢刷新。
            if time.ticks_diff(now_ms, last_log_ms) >= 500:
                if reading is None:
                    print("Pinch: NO HAND / INVALID KEYPOINTS")
                else:
                    print("Pinch: %.1f px, ratio %.3f, volume %d%%" % (
                        reading["distance_px"], reading["ratio"], reading["percent"]))
                last_log_ms = now_ms
            del frame
            gc.collect()
            time.sleep_ms(1)
    except KeyboardInterrupt:
        print("Stopped by user.")
    except Exception as error:
        print("FAILED at:", stage)
        sys.print_exception(error)
        raise
    finally:
        release("keypoints", keypoints)
        release("detector", detector)
        if pl is not None:
            try:
                pl.destroy()
            except Exception as error:
                print("Cleanup pipeline:", error)
        gc.collect()


if __name__ == "__main__":
    main()
