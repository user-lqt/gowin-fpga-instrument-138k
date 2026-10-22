# -*- coding: utf-8 -*-
"""亚博 CanMV K230：捏合调音量 + 动态挥手切音色的独立屏幕测试。

单文件运行，使用配套固件和三个模型；不发送串口数据，不输出音频。
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


def release(name, obj):
    if obj is not None:
        try:
            obj.deinit()
        except Exception as error:
            print("Cleanup", name, error)


# ---------- 动态手势模型与音乐控制 ----------
TIMBRE_NAMES = ("音色 1", "音色 2")  # 仅演示编号；还没有向 FPGA 发送命令。
INITIAL_VOLUME = 50
PALM_HOLD_MS = 400
PINCH_HOLD_MS = 200
WAVE_TIMEOUT_MS = 2000
RELEASE_HOLD_MS = 300
WAVE_COOLDOWN_MS = 900
SWAP_LEFT_RIGHT = False  # 若需要按操作者左右而非屏幕左右定义，可设 True。
MIN_WAVE_PIXELS = 35.0
MIN_WAVE_PALMS = 0.45


def finger_angles(points):
    if points is None or len(points) != 42:
        return None
    if not all(math.isfinite(float(v)) for v in points):
        return None
    angles = []
    for finger in range(5):
        j = finger * 8
        ax, ay = points[0] - points[j + 4], points[1] - points[j + 5]
        bx, by = points[j + 6] - points[j + 8], points[j + 7] - points[j + 9]
        norm = math.sqrt((ax * ax + ay * ay) * (bx * bx + by * by))
        if norm < 0.000001:
            return None
        cosine = max(-1.0, min(1.0, (ax * bx + ay * by) / norm))
        angles.append(math.acos(cosine) * 180.0 / math.pi)
    return angles


def pose_kind(points):
    # 调音量不要求拇指/食指一直伸直，只要求其余三指收拢。
    # 张掌有独立入口，避免挥手时指尖距离把音量推大。
    if measure_pinch(points) is None:
        return "NONE"
    angles = finger_angles(points)
    if angles is None:
        return "OTHER"
    if all(angle < 49 for angle in angles):
        return "PALM"
    if all(angle > 65 for angle in angles[2:]):
        return "PINCH"
    return "OTHER"


class WaveEvidence:
    """沿用配套例程的左右类别和累计分数门槛，限制缓存长度。

    模型分数只作判定依据，不显示成“置信度百分比”。
    无动作、其他方向或方向改变会清除连续证据。
    """
    DIRECTIONS = {11: "RIGHT", 16: "RIGHT", 12: "LEFT", 17: "LEFT"}

    def __init__(self):
        self.reset()

    def reset(self):
        self.direction = None
        self.scores = []

    def update(self, scores):
        if len(scores) != 27 or not all(math.isfinite(float(v)) for v in scores):
            self.reset()
            return None
        index = max(range(27), key=lambda i: float(scores[i]))
        direction = self.DIRECTIONS.get(index)
        if direction is None:
            self.reset()
            return None
        if direction != self.direction:
            self.reset()
            self.direction = direction
        self.scores.append([float(v) for v in scores])
        if len(self.scores) > 4:
            del self.scores[0]
        # 同一方向的两个模型类别分别累加，不把不同类别的分数混加。
        peak = max(sum(row[i] for row in self.scores)
                   for i in self.DIRECTIONS if self.DIRECTIONS[i] == direction)
        count = len(self.scores)
        if (count >= 2 and peak >= 0.4) or (count >= 3 and peak >= 0.3):
            return direction
        return None


class MusicControl:
    """屏幕演示状态机；参数保持与单次事件判定均不依赖模型库。"""
    def __init__(self):
        self.pinch = PinchControl()
        self.pinch.percent = float(INITIAL_VOLUME)
        self.pinch.accepted_target = float(INITIAL_VOLUME)
        self.timbre = 0
        self.mode = "IDLE"
        self.pose = "NONE"
        self.measurement = None
        self.palm_ms = 0.0
        self.pinch_ms = 0.0
        self.release_ms = 0.0
        self.wave_ms = 0.0
        self.cooldown_ms = 0.0
        self.event_age_ms = 2000.0
        self.last_event = "等待操作"
        self.anchor = None
        self.shift = None
        self.wave_min = MIN_WAVE_PIXELS
        self.model_direction = None
        self.evidence = WaveEvidence()

    def volume(self):
        return int(self.pinch.percent + 0.5)

    def end_wave(self, message):
        self.mode = "RELEASE"
        self.cooldown_ms = float(WAVE_COOLDOWN_MS)
        self.release_ms = 0.0
        self.last_event = message
        self.event_age_ms = 0.0
        self.model_direction = None
        self.evidence.reset()

    def update_pose(self, points, elapsed_ms):
        elapsed_ms = max(0.0, float(elapsed_ms))
        # 长帧不能被当成连续保持同一个姿势。
        hold_step = min(elapsed_ms, MAX_STEP_MS)
        previous_pose = self.pose
        self.pose = pose_kind(points)
        self.measurement = measure_pinch(points)
        self.event_age_ms += elapsed_ms
        self.cooldown_ms = max(0.0, self.cooldown_ms - elapsed_ms)
        if elapsed_ms > 400:
            self.palm_ms = self.pinch_ms = self.release_ms = 0.0
            self.evidence.reset()

        if self.mode == "WAVE":
            self.wave_ms += elapsed_ms
            if self.pose == "NONE":
                self.end_wave("手已移开，音量和音色保持")
            elif self.wave_ms >= WAVE_TIMEOUT_MS:
                self.end_wave("挥手超时，请收手后重试")
            else:
                center = ((points[0] + points[18]) / 2,
                          (points[1] + points[19]) / 2)
                self.shift = (center[0] - self.anchor[0], center[1] - self.anchor[1])
            return

        if self.mode == "RELEASE":
            # 必须先收拢/移开，再重新张掌；一直张掌不会连续切换。
            if self.pose != "PALM":
                self.release_ms += hold_step
            else:
                self.release_ms = 0.0
            if self.release_ms >= RELEASE_HOLD_MS and self.cooldown_ms == 0:
                self.mode = "IDLE"
                self.palm_ms = self.pinch_ms = 0.0
            return

        if self.pose == "PALM":
            self.pinch_ms = 0.0
            self.palm_ms = self.palm_ms + hold_step if previous_pose == "PALM" else 0.0
            if self.palm_ms >= PALM_HOLD_MS:
                self.mode = "WAVE"
                self.wave_ms = 0.0
                self.anchor = ((points[0] + points[18]) / 2,
                               (points[1] + points[19]) / 2)
                self.shift = (0.0, 0.0)
                self.wave_min = max(MIN_WAVE_PIXELS, self.measurement[2] * MIN_WAVE_PALMS)
                self.model_direction = None
                self.evidence.reset()
            return

        self.palm_ms = 0.0
        if self.pose == "PINCH":
            if previous_pose != "PINCH":
                self.pinch_ms = 0.0
                # 接续保存的音量，重新进入不会直接跳到新姿势对应值。
                self.pinch.accepted_target = self.pinch.percent
            self.pinch_ms += hold_step
            if self.pinch_ms >= PINCH_HOLD_MS:
                self.pinch.update(points, hold_step)
        else:
            self.pinch_ms = 0.0

    def update_wave(self, scores):
        if self.mode != "WAVE":
            return None
        direction = self.evidence.update(scores)
        self.model_direction = direction
        if direction is None or self.shift is None:
            return None
        dx, dy = self.shift
        # 模型确认“横向挥手”，屏幕坐标决定左右。配套例程的类别方向
        # 命名受镜像影响，不能直接拿它与关键点位移的正负号比较。
        moved = abs(dx) >= self.wave_min and abs(dx) >= abs(dy) * 1.2
        if not moved:
            return None
        direction = "RIGHT" if dx > 0 else "LEFT"
        if SWAP_LEFT_RIGHT:
            direction = "RIGHT" if direction == "LEFT" else "LEFT"
        change = -1 if direction == "LEFT" else 1
        self.timbre = (self.timbre + change) % len(TIMBRE_NAMES)
        self.end_wave("向左：上一音色" if direction == "LEFT" else "向右：下一音色")
        return direction


class DynamicModel(AIBase):
    """亚博 gesture.kmodel：224x224 图像 + 10 个跨帧状态输入。"""
    SHAPES = ([1, 3, 224, 224], [1, 3, 56, 56], [1, 4, 28, 28],
              [1, 4, 28, 28], [1, 8, 14, 14], [1, 8, 14, 14],
              [1, 8, 14, 14], [1, 12, 14, 14], [1, 12, 14, 14],
              [1, 20, 7, 7], [1, 20, 7, 7])

    def __init__(self, path):
        super().__init__(path, [224, 224], CAMERA_SIZE, 0)
        self.ai2d_resize = Ai2d(0)
        self.ai2d_crop = Ai2d(0)
        for processor in (self.ai2d_resize, self.ai2d_crop):
            processor.set_ai2d_dtype(nn.ai2d_format.NCHW_FMT, nn.ai2d_format.NCHW_FMT,
                                    np.uint8, np.uint8)
        self.mean = np.array([0.485, 0.456, 0.406]).reshape((3, 1, 1))
        self.std = np.array([0.229, 0.224, 0.225]).reshape((3, 1, 1))
        self.first_data = np.zeros(self.SHAPES[0], dtype=np.float)
        self.input_tensors = []

    def config_preprocess(self):
        if self.get_kmodel_inputs_num() != 11 or self.get_kmodel_outputs_num() != 11:
            raise RuntimeError("gesture.kmodel must have 11 inputs and 11 outputs; use matching Yahboom model")
        w, h = CAMERA_SIZE
        ratio = max(256.0 / w, 256.0 / h)
        nw, nh = int(w * ratio), int(h * ratio)
        self.ai2d_resize.resize(nn.interp_method.tf_bilinear, nn.interp_mode.half_pixel)
        self.ai2d_resize.build([1, 3, h, w], [1, 3, nh, nw])
        self.ai2d_crop.crop((nw - 224) // 2, (nh - 224) // 2, 224, 224)
        self.ai2d_crop.build([1, 3, nh, nw], [1, 3, 224, 224])
        self.reset()

    def reset(self):
        self.input_tensors.clear()
        self.input_tensors.append(nn.from_numpy(self.first_data))
        for shape in self.SHAPES[1:]:
            self.input_tensors.append(nn.from_numpy(np.zeros(shape, dtype=np.float)))
        self.results.clear()

    def run(self, frame):
        resized = self.ai2d_resize.run(frame)
        cropped = self.ai2d_crop.run(resized.to_numpy())
        self.first_data[0] = cropped.to_numpy()[0].copy()
        self.first_data[0] = (self.first_data[0] / 255.0 - self.mean) / self.std
        self.input_tensors[0] = nn.from_numpy(self.first_data)
        outputs = self.inference(self.input_tensors)
        for index in range(1, 11):
            self.input_tensors[index] = nn.from_numpy(outputs[index])
        values = outputs[0].reshape((27,))
        return [float(values[index]) for index in range(27)]

    def deinit(self):
        self.input_tensors.clear()
        self.first_data = None
        self.mean = self.std = None
        self.results.clear()
        self.ai2d_resize = self.ai2d_crop = None
        super().deinit()


def find_music_models():
    directories = (MODEL_DIR,) if MODEL_DIR else MODEL_DIRS
    names = ("hand_det.kmodel", "handkp_det.kmodel", "gesture.kmodel")
    for directory in directories:
        paths = tuple(directory + "/" + name for name in names)
        try:
            if all(os.stat(path)[6] > 0 for path in paths):
                return paths
        except OSError:
            pass
    raise RuntimeError("Missing matching Yahboom models: " + str(names)
                       + ". Checked: " + str(directories))


def control_status(control):
    if control.mode == "WAVE":
        return "请左右挥手（音量锁定）"
    if control.mode == "RELEASE":
        return "请收拢手指或移开，再张掌"
    if control.pose == "PALM":
        return "张掌保持，准备切换音色"
    if control.pose == "PINCH":
        return "捏合调节中" if control.pinch_ms >= PINCH_HOLD_MS else "保持捏合姿势"
    if control.pose == "NONE":
        return "未检测到有效手，参数保持"
    return "其余三指收拢，再调拇食指"


def draw_music_frame(pl, box, points, control, fps):
    canvas = pl.osd_img
    canvas.clear()
    w, h = pl.display_size
    bg, white = (255, 15, 20, 30), (255, 255, 255, 255)
    green, yellow = (255, 0, 255, 130), (255, 255, 220, 0)
    if box is not None:
        x1, y1 = screen_xy(float(box[2]), float(box[3]), pl.display_size)
        x2, y2 = screen_xy(float(box[4]), float(box[5]), pl.display_size)
        canvas.draw_rectangle(x1, y1, max(1, x2 - x1), max(1, y2 - y1), color=green, thickness=2)
    if points is not None:
        coords = [screen_xy(points[i * 2], points[i * 2 + 1], pl.display_size) for i in range(21)]
        for finger in range(5):
            previous = 0
            for joint in range(1 + finger * 4, 5 + finger * 4):
                canvas.draw_line(coords[previous][0], coords[previous][1], coords[joint][0],
                                 coords[joint][1], color=(255, 120, 170, 210), thickness=1)
                previous = joint
        for index in (4, 8):
            canvas.draw_circle(coords[index][0], coords[index][1], 6, color=yellow, fill=True)
        canvas.draw_line(coords[4][0], coords[4][1], coords[8][0], coords[8][1], color=yellow, thickness=3)
    if control.mode == "WAVE":
        canvas.draw_rectangle(110, 30, 420, 420, color=yellow, thickness=2)

    canvas.draw_rectangle(0, 0, w, 112, color=bg, fill=True)
    canvas.draw_string_advanced(10, 5, 24, "K230 手势音乐控制测试", color=white)
    canvas.draw_string_advanced(w - 130, 8, 18, "FPS: %.1f" % fps, color=white)
    canvas.draw_string_advanced(10, 36, 28, "模拟音量: %d%%" % control.volume(), color=green)
    canvas.draw_string_advanced(340, 36, 28, "当前: " + TIMBRE_NAMES[control.timbre], color=yellow)
    text = "距离: -- px  相对: --" if control.measurement is None else (
        "距离: %.1f px  相对: %.2f" % control.measurement[:2])
    canvas.draw_string_advanced(10, 78, 20, text, color=white)
    panel_y = h - 140
    canvas.draw_rectangle(0, panel_y, w, 140, color=bg, fill=True)
    canvas.draw_string_advanced(10, panel_y + 4, 24, control_status(control), color=yellow)
    canvas.draw_rectangle(12, panel_y + 40, w - 24, 22, color=white, thickness=2)
    fill = (w - 30) * control.volume() // 100
    if fill > 0:
        canvas.draw_rectangle(15, panel_y + 43, fill, 16, color=green, fill=True)
    event = control.last_event if control.event_age_ms < 1800 else "仅屏幕演示，尚未连接乐器"
    canvas.draw_string_advanced(10, panel_y + 70, 22, event, color=white)
    canvas.draw_string_advanced(10, h - 32, 20, "三指收拢调音量 / 张掌后挥手换音色", color=white)


def main():
    pl, detector, keypoints, dynamic = None, None, None, None
    stage = "check model files"
    try:
        os.exitpoint(os.EXITPOINT_ENABLE)
        paths = find_music_models()
        print("Models:", paths)
        print("Only K230 screen simulation. No UART or audio output.")
        stage = "create camera and LCD"
        control = MusicControl()
        pl = PipeLine(rgb888p_size=CAMERA_SIZE, display_size=DISPLAY_SIZE, display_mode="lcd")
        pl.create(hmirror=True)
        draw_music_frame(pl, None, None, control, 0)
        pl.show_image()
        stage = "load hand detector"
        detector = HandDetector(paths[0])
        detector.config_preprocess()
        stage = "load hand keypoints"
        keypoints = HandKeypoints(paths[1])
        stage = "load dynamic gesture model"
        dynamic = DynamicModel(paths[2])
        dynamic.config_preprocess()
        clock = time.clock()
        previous_ms = last_log_ms = time.ticks_ms()
        stage = "gesture music control loop"
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
            previous_mode = control.mode
            control.update_pose(points, time.ticks_diff(now_ms, previous_ms))
            previous_ms = now_ms
            if control.mode == "WAVE":
                if previous_mode != "WAVE":
                    dynamic.reset()
                direction = control.update_wave(dynamic.run(frame))
                if direction is not None:
                    print("TIMBRE EVENT:", direction, "index", control.timbre + 1,
                          "volume", control.volume())
            if previous_mode == "WAVE" and control.mode != "WAVE":
                dynamic.reset()
            draw_music_frame(pl, box, points, control, clock.fps())
            pl.show_image()
            if time.ticks_diff(now_ms, last_log_ms) >= 500:
                print("mode", control.mode, "pose", control.pose, "volume", control.volume(),
                      "timbre", control.timbre + 1, "wave_dx_dy", control.shift,
                      "model_direction", control.model_direction)
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
        release("dynamic", dynamic)
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
