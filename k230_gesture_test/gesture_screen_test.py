# -*- coding: utf-8 -*-
"""亚博 CanMV K230：手势识别 + 配套 640x480 LCD。

在 CanMV IDE 中打开并运行本文件。依赖配套固件内的 libs 和 TF 卡模型。
基于亚博 程序源码/08.Body/07.hand_keypoint_class.py 的模型及预处理配置。
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


# 与用户下载的亚博例程保持一致，显示于 K230 自带屏幕。
DISPLAY_MODE = "lcd"
DISPLAY_SIZE = [640, 480]
CAMERA_SIZE = [640, 480]
CONFIDENCE = 0.20
STABLE_FRAMES = 3

# 留空会查找配套固件常用目录；自定义时填写板端路径，不是电脑盘符。
MODEL_DIR = ""
MODEL_DIRS = (
    "/sdcard/kmodel",
    "/sdcard/examples/kmodel",
    "/sdcard/app/tests/kmodel",
)
ANCHORS = [26, 27, 53, 52, 75, 71, 80, 99, 106, 82,
           99, 134, 140, 113, 161, 172, 245, 276]
LABELS = {
    "fist": "FIST 握拳", "five": "FIVE 张掌", "yeah": "YEAH 剪刀手",
    "one": "ONE 数字一", "six": "SIX 数字六", "three": "THREE 数字三",
    "thumbUp": "THUMB UP 竖拇指", "gun": "GUN 手枪", "love": "LOVE 手势",
    "UNKNOWN": "UNKNOWN 未识别", "WAIT": "WAIT 请保持手势",
    "NO HAND": "NO HAND 未检测到手",
}
FINGER_COLORS = ((255, 255, 80, 80), (255, 255, 80, 255),
                 (255, 255, 255, 0), (255, 0, 255, 0), (255, 0, 180, 255))


def vector_angle(v1, v2):
    """返回角度；退化向量返回 None，避免把无效关键点判成张掌。"""
    x1, y1 = float(v1[0]), float(v1[1])
    x2, y2 = float(v2[0]), float(v2[1])
    norm = math.sqrt((x1 * x1 + y1 * y1) * (x2 * x2 + y2 * y2))
    if norm < 0.000001:
        return None
    cosine = (x1 * x2 + y1 * y2) / norm
    if not math.isfinite(cosine):
        return None
    return math.acos(max(-1.0, min(1.0, cosine))) * 180.0 / math.pi


def classify_gesture(points):
    # 在原始摄像头坐标中计算角度，避免屏幕比例影响分类。
    if len(points) != 42:
        return "UNKNOWN"
    angles = []
    for finger in range(5):
        j = finger * 8
        angle = vector_angle((points[0] - points[j + 4], points[1] - points[j + 5]),
                             (points[j + 6] - points[j + 8], points[j + 7] - points[j + 9]))
        if angle is None:
            return "UNKNOWN"
        angles.append(angle)
    t, i, m, r, p = angles
    # 延用配套例程的角度阈值，属于关键点几何规则，不是分类概率。
    if t > 53 and i > 65 and m > 65 and r > 65 and p > 65:
        return "fist"
    if t < 49 and i < 49 and m < 49 and r < 49 and p < 49:
        return "five"
    if t < 49 and i < 49 and m > 65 and r > 65 and p > 65:
        return "gun"
    if t < 49 and i < 49 and m > 65 and r > 65 and p < 49:
        return "love"
    if t > 5 and i < 49 and m > 65 and r > 65 and p > 65:
        return "one"
    if t < 49 and i > 65 and m > 65 and r > 65 and p < 49:
        return "six"
    if t > 53 and i < 49 and m < 49 and r < 49 and p > 65:
        return "three"
    if t < 49 and i > 65 and m > 65 and r > 65 and p > 65:
        return "thumbUp"
    if t > 53 and i < 49 and m < 49 and r > 65 and p > 65:
        return "yeah"
    return "UNKNOWN"


class GestureFilter:
    """连续若干帧一致才确认；手移走或关键点无效时立即清除。"""
    def __init__(self, frames=STABLE_FRAMES):
        self.frames = max(1, int(frames))
        self.candidate = None
        self.count = 0

    def update(self, raw):
        if raw in ("NO HAND", "UNKNOWN"):
            self.candidate = None
            self.count = 0
            return raw
        if raw == self.candidate:
            self.count = min(self.frames, self.count + 1)
        else:
            self.candidate = raw
            self.count = 1
        return raw if self.count >= self.frames else "WAIT"


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
                       + str(directories) + ". See README.md; use matching Yahboom models.")


class HandDetector(AIBase):
    def __init__(self, path):
        super().__init__(path, [512, 512], CAMERA_SIZE, 0)
        self.ai2d = Ai2d(0)
        self.ai2d.set_ai2d_dtype(nn.ai2d_format.NCHW_FMT, nn.ai2d_format.NCHW_FMT,
                                np.uint8, np.uint8)

    def config_preprocess(self):
        w, h = CAMERA_SIZE
        ratio = min(512.0 / w, 512.0 / h)
        dw = (512 - int(w * ratio)) / 2
        dh = (512 - int(h * ratio)) / 2
        self.ai2d.pad([0, 0, 0, 0, int(round(dh - 0.1)), int(round(dh + 0.1)),
                       int(round(dw - 0.1)), int(round(dw + 0.1))], 0, [114, 114, 114])
        self.ai2d.resize(nn.interp_method.tf_bilinear, nn.interp_mode.half_pixel)
        self.ai2d.build([1, 3, h, w], [1, 3, 512, 512])

    def postprocess(self, results):
        return aicube.anchorbasedet_post_process(
            results[0], results[1], results[2], [512, 512], CAMERA_SIZE,
            [8, 16, 32], 1, CONFIDENCE, 0.5, ANCHORS, False)


def crop_for_hand(box, size):
    x1, y1, x2, y2 = [float(v) for v in box[2:6]]
    cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    half = 1.26 * max(x2 - x1, y2 - y1) / 2
    left = max(0, min(size[0] - 1, int(cx - half)))
    top = max(0, min(size[1] - 1, int(cy - half)))
    right = max(left, min(size[0] - 1, int(cx + half)))
    bottom = max(top, min(size[1] - 1, int(cy + half)))
    return [left, top, right - left + 1, bottom - top + 1]


def decode_points(values, crop):
    # crop = [x, y, 宽, 高]。原例程此处把宽、高用反了，边缘裁剪时会失真。
    x, y, width, height = crop
    points = []
    for index in range(21):
        px = float(values[index * 2])
        py = float(values[index * 2 + 1])
        if not math.isfinite(px) or not math.isfinite(py):
            return None
        points.extend((px * width + x, py * height + y))
    return points


class HandKeypoints(AIBase):
    def __init__(self, path):
        super().__init__(path, [256, 256], CAMERA_SIZE, 0)
        self.crop = None
        self.ai2d = Ai2d(0)
        self.ai2d.set_ai2d_dtype(nn.ai2d_format.NCHW_FMT, nn.ai2d_format.NCHW_FMT,
                                np.uint8, np.uint8)

    def config_preprocess(self, box):
        self.crop = crop_for_hand(box, CAMERA_SIZE)
        self.ai2d.crop(*self.crop)
        self.ai2d.resize(nn.interp_method.tf_bilinear, nn.interp_mode.half_pixel)
        self.ai2d.build([1, 3, CAMERA_SIZE[1], CAMERA_SIZE[0]], [1, 3, 256, 256])

    def postprocess(self, results):
        return decode_points(results[0].reshape((42,)), self.crop)


def choose_hand(boxes):
    # 此测试只处理最大的一只手，避免多人画面影响演示。
    best, best_area = None, 0
    for box in boxes:
        x1, y1, x2, y2 = box[2:6]
        width, height = float(x2 - x1), float(y2 - y1)
        if width < 20 or height < CAMERA_SIZE[1] * 0.1:
            continue
        if x2 <= 0 or y2 <= 0 or x1 >= CAMERA_SIZE[0] or y1 >= CAMERA_SIZE[1]:
            continue
        area = width * height
        if area > best_area:
            best, best_area = box, area
    return best


def screen_xy(x, y, size):
    sx = int(float(x) * size[0] / CAMERA_SIZE[0])
    sy = int(float(y) * size[1] / CAMERA_SIZE[1])
    return max(0, min(size[0] - 1, sx)), max(0, min(size[1] - 1, sy))


def draw_frame(pl, box, points, raw, stable, fps):
    canvas = pl.osd_img
    canvas.clear()
    size = pl.display_size
    if box is not None:
        x1, y1 = screen_xy(box[2], box[3], size)
        x2, y2 = screen_xy(box[4], box[5], size)
        canvas.draw_rectangle(x1, y1, max(1, x2 - x1), max(1, y2 - y1),
                              color=(255, 0, 255, 0), thickness=2)
    if points is not None:
        coords = [screen_xy(points[2 * i], points[2 * i + 1], size) for i in range(21)]
        for finger in range(5):
            previous = 0
            for joint in range(1 + finger * 4, 5 + finger * 4):
                canvas.draw_line(coords[previous][0], coords[previous][1],
                                 coords[joint][0], coords[joint][1],
                                 color=FINGER_COLORS[finger], thickness=2)
                previous = joint
        for x, y in coords:
            canvas.draw_circle(x, y, 3, color=(255, 255, 255, 255), fill=True)
    canvas.draw_rectangle(0, 0, size[0], 90, color=(255, 15, 20, 30), fill=True)
    color = (255, 0, 255, 120) if stable not in ("NO HAND", "UNKNOWN", "WAIT") else (255, 255, 215, 0)
    canvas.draw_string_advanced(10, 5, 24, "K230 手势测试  FPS: %.1f" % fps,
                                color=(255, 255, 255, 255))
    canvas.draw_string_advanced(10, 35, 30, LABELS.get(stable, stable), color=color)
    canvas.draw_string_advanced(10, 69, 16, "RAW: " + raw, color=(255, 180, 190, 200))
    canvas.draw_rectangle(0, size[1] - 32, size[0], 32, color=(255, 15, 20, 30), fill=True)
    canvas.draw_string_advanced(10, size[1] - 29, 20, "单手对准镜头：张掌 / 握拳 / 剪刀手",
                                color=(255, 255, 255, 255))


def release(name, obj):
    if obj is not None:
        try:
            obj.deinit()
        except Exception as error:
            print("Cleanup", name, error)


def main():
    pl, detector, keypoints = None, None, None
    stage = "check model files"
    try:
        os.exitpoint(os.EXITPOINT_ENABLE)
        det_path, kp_path = find_models()
        print("Hand detector:", det_path)
        print("Hand keypoints:", kp_path)
        stage = "create camera and LCD"
        pl = PipeLine(rgb888p_size=CAMERA_SIZE, display_size=DISPLAY_SIZE,
                      display_mode=DISPLAY_MODE)
        pl.create()
        draw_frame(pl, None, None, "NO HAND", "NO HAND", 0)
        pl.show_image()
        stage = "load hand detector"
        detector = HandDetector(det_path)
        detector.config_preprocess()
        stage = "load hand keypoints"
        keypoints = HandKeypoints(kp_path)
        gesture_filter = GestureFilter()
        clock = time.clock()
        last_status = None
        stage = "gesture loop"
        print("Ready. Try FIVE, FIST, YEAH. Stop with the IDE stop button.")
        while True:
            os.exitpoint()
            clock.tick()
            frame = pl.get_frame()
            box = choose_hand(detector.run(frame))
            points = None
            raw = "NO HAND"
            if box is not None:
                keypoints.config_preprocess(box)
                points = keypoints.run(frame)
                raw = classify_gesture(points) if points is not None else "UNKNOWN"
            stable = gesture_filter.update(raw)
            draw_frame(pl, box, points, raw, stable, clock.fps())
            pl.show_image()
            if stable != last_status:
                print("Gesture:", stable)
                last_status = stable
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
        # 放在 finally 中，IDE 停止和异常退出均可执行。
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
