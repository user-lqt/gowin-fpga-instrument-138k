# -*- coding: utf-8 -*-
"""亚博 CanMV K230：手掌高度调音量、静态手势选音色。LCD 与 IDE 同步显示。

直接运行时仅屏幕测试。gesture_fpga_control.py 可注入独立 UART 参数接口。
"""
import os
import sys
import time
import math
import gc
for lib_root in ("/sdcard", "/sdcard/app"):
    if lib_root not in sys.path:
        sys.path.append(lib_root)
from libs.AIBase import AIBase
from libs.AI2D import Ai2d
from media.sensor import Sensor, CAM_CHN_ID_0, CAM_CHN_ID_2, PIXEL_FORMAT_YUV_SEMIPLANAR_420, PIXEL_FORMAT_RGB_888_PLANAR
from media.display import Display
from media.media import MediaManager
import image
import nncase_runtime as nn
import ulab.numpy as np
import aicube
DISPLAY_SIZE = [640, 480]
CAMERA_SIZE = [640, 480]
MODEL_DIR = ""
MODEL_DIRS = ("/sdcard/kmodel", "/sdcard/examples/kmodel", "/sdcard/app/tests/kmodel")
CONFIDENCE = 0.20
ANCHORS = [26, 27, 53, 52, 75, 71, 80, 99, 106, 82, 99, 134, 140, 113, 161, 172, 245, 276]

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
        crop = [left, top, right - left + 1, bottom - top + 1]
        if crop == self.crop:
            return False
        self.ai2d.crop(*crop)
        self.ai2d.resize(nn.interp_method.tf_bilinear, nn.interp_mode.half_pixel)
        self.ai2d.build([1, 3, CAMERA_SIZE[1], CAMERA_SIZE[0]], [1, 3, 256, 256])
        self.crop = crop
        return True

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


def find_music_models():
    directories = (MODEL_DIR,) if MODEL_DIR else MODEL_DIRS
    names = ("hand_det.kmodel", "handkp_det.kmodel")
    for directory in directories:
        paths = tuple(directory + "/" + name for name in names)
        try:
            if all(os.stat(path)[6] > 0 for path in paths):
                return paths
        except OSError:
            pass
    raise RuntimeError("Missing matching Yahboom models: " + str(names)
                       + ". Checked: " + str(directories))


# ---------- 手掌高度调音量、静态手势选页与选音色 ----------
BUILD_TAG = "TOUCH KEYS V4.9 UART3 GPIO32/33"
TOUCH_POLL_MS = 5
TOUCH_REDRAW_MS = 50
CAMERA_HMIRROR = False  # 关闭原有左右镜像；视频与 AI 使用同一传感器方向。
TOUCH_BUTTONS = ((20, 278, 185, 72), (227, 278, 185, 72), (434, 278, 185, 72))
TOUCH_SLIDER = (40, 382, 560, 66)
INPUT_TABS = ((10, 38, 200, 72), (220, 38, 200, 72), (430, 38, 200, 72))
INPUT_MODES = ("GESTURE", "TOUCH", "KEYS")
INPUT_LABELS = ("1 手势", "2 调参", "3 琴键")
KEY_NOTES = (60, 62, 64, 65, 67, 69, 71, 72)
KEY_LABELS = ("C4", "D4", "E4", "F4", "G4", "A4", "B4", "C5")
KEY_RECTS = ((16, 268, 140, 76), (172, 268, 140, 76), (328, 268, 140, 76), (484, 268, 140, 76),
             (16, 358, 140, 76), (172, 358, 140, 76), (328, 358, 140, 76), (484, 358, 140, 76))
TEXT_SHADOW = False
PERF_REPORT_MS = 2000
TIMBRE_NAMES = ("钢琴", "吉他", "编钟")
PAGES = ("TIMBRE", "VOLUME")
PAGE_NAMES = ("音色", "音量")
POSE_LABELS = {"V_SIGN": "剪刀手", "PALM": "张掌", "FIST": "握拳",
               "OTHER": "未识别", "NONE": "无手"}
INITIAL_VOLUME = 50
GESTURE_HOLD_MS = 450
RELEASE_HOLD_MS = 300
LOST_RELEASE_MS = 600
MIN_CONFIRM_FRAMES = 3
MAX_HOLD_STEP_MS = 150
MAX_FRAME_GAP_MS = 500
PALM_CENTER_INDICES = (0, 5, 9, 13, 17)
HEIGHT_TOP_RATIO = 0.40
HEIGHT_BOTTOM_RATIO = 0.78
HEIGHT_DEADBAND_PERCENT = 3.0
HEIGHT_SMOOTH_MS = 500.0
HEIGHT_MAX_RATE = 20.0
HEIGHT_VOLUME_STEP = 5
HEIGHT_OUTPUT_HYSTERESIS = 0.75


def palm_geometry(points):
    """验证关键点和手掌大小；无运动门槛，不比较前后帧位置。"""
    if points is None or len(points) != 42:
        return None
    if not all(math.isfinite(float(value)) for value in points):
        return None
    for index in range(21):
        if not (0 <= points[index * 2] < CAMERA_SIZE[0]
                and 0 <= points[index * 2 + 1] < CAMERA_SIZE[1]):
            return None
    length = math.sqrt((points[18] - points[0]) ** 2 + (points[19] - points[1]) ** 2)
    if length < 20:
        return None
    return ((points[0] + points[18]) / 2, (points[1] + points[19]) / 2, length)


def pose_kind(points):
    geometry = palm_geometry(points)
    if geometry is None:
        return "NONE"
    angles = finger_angles(points)
    if angles is None:
        return "OTHER"
    thumb, index, middle, ring, pinky = angles
    # 只识别三种轮廓差别较大的手势；中间角度保留为 OTHER。
    if index < 49 and middle < 49 and ring > 65 and pinky > 65:
        return "V_SIGN"
    if all(angle < 49 for angle in angles[1:]):
        return "PALM"
    if all(angle > 65 for angle in angles[1:]):
        if thumb > 53:
            return "FIST"
    return "OTHER"


def palm_height_reading(points):
    """掌心高度取手腕与四指根的均值，不使用会随伸指变化的指尖。"""
    if palm_geometry(points) is None:
        return None
    cx = sum(points[index * 2] for index in PALM_CENTER_INDICES) / 5
    cy = sum(points[index * 2 + 1] for index in PALM_CENTER_INDICES) / 5
    top = CAMERA_SIZE[1] * HEIGHT_TOP_RATIO
    bottom = CAMERA_SIZE[1] * HEIGHT_BOTTOM_RATIO
    target = max(0.0, min(100.0, 100.0 * (bottom - cy) / (bottom - top)))
    return cx, cy, target


def volume_level(volume):
    """输出为 0、5、10……100；保留 0% 静音档。"""
    value = max(0.0, min(100.0, float(volume)))
    return min(100, int(value / HEIGHT_VOLUME_STEP + 0.5) * HEIGHT_VOLUME_STEP)


class HeightVolumeFilter:
    """连续值平滑限速，输出 5% 档位；回差抑制档位边界反复切换。"""
    def __init__(self, volume):
        self.reset(volume)

    def reset(self, volume):
        self.level = volume_level(volume)
        self.percent = float(self.level)
        self.target = float(self.level)

    def update(self, target, elapsed_ms):
        if not math.isfinite(float(target)):
            return self.level
        target = max(0.0, min(100.0, float(target)))
        # 固定目标直到超过死区，避免手掌微抖让音量来回变化。
        if target in (0.0, 100.0) or abs(target - self.target) >= HEIGHT_DEADBAND_PERCENT:
            self.target = target
        dt = max(0.0, min(float(elapsed_ms), MAX_HOLD_STEP_MS))
        alpha = 1.0 - math.exp(-dt / HEIGHT_SMOOTH_MS)
        change = (self.target - self.percent) * alpha
        limit = HEIGHT_MAX_RATE * dt / 1000.0
        self.percent = max(0.0, min(100.0, self.percent + max(-limit, min(limit, change))))
        candidate = volume_level(self.percent)
        # 比半档多留 0.75 个百分点；目标在档位交界轻微摆动时保持原档。
        if (candidate != self.level
                and abs(self.percent - self.level) >= HEIGHT_VOLUME_STEP / 2 + HEIGHT_OUTPUT_HYSTERESIS):
            self.level = candidate
        return self.level


class PageControl:
    """握拳循环选页、剪刀手循环音色、张掌高度音量；离手保持参数。"""
    def __init__(self):
        self.page = self.timbre = 0
        self.volume = INITIAL_VOLUME
        self.enabled = True
        self.mode = "ACTIVE"
        self.pose = "NONE"
        self.candidate = None
        self.candidate_ms = 0.0
        self.candidate_frames = 0
        self.latched = None
        self.release_ms = 0.0
        self.lost_ms = 0.0
        self.height_filter = HeightVolumeFilter(self.volume)
        self.height_active = False
        self.height_y = None
        self.height_target = None
        self.event_age_ms = 2000.0
        self.last_event = "握拳换页，剪刀手换音色"
        self.last_source = None
        self.tx_count = 0
        self.link_active = False
        self.touch_ready = False
        self.touch_note = None
        self.input_mode = "GESTURE"
        self.touch_active = False
        self.touch_lock = False
        self.touch_release_ms = 0.0

    def action_available(self, pose):
        return (pose == "FIST" or pose == "V_SIGN" and PAGES[self.page] == "TIMBRE"
                or pose == "PALM" and PAGES[self.page] == "VOLUME")

    def clear_candidate(self):
        self.candidate = None
        self.candidate_ms = 0.0
        self.candidate_frames = 0

    def stop_height(self):
        if self.height_active and self.latched == "PALM":
            self.latched = None
        self.height_active = False
        self.height_y = self.height_target = None
        self.height_filter.reset(self.volume)

    def update_height(self, points, elapsed_ms):
        reading = palm_height_reading(points)
        if reading is None:
            self.stop_height()
            return None
        self.height_y, self.height_target = reading[1], reading[2]
        previous = self.volume
        self.volume = self.height_filter.update(self.height_target, elapsed_ms)
        if self.volume != previous:
            self.emit("音量: %d%%" % self.volume, "PALM_HEIGHT")
            return "VOLUME"
        return None

    def confirm_progress(self):
        if (self.candidate is None or self.latched is not None
                or not self.action_available(self.candidate)):
            return 0
        # 100% 留给实际执行结果；不适用当前页的手势不显示假进度。
        return min(99, int(100 * self.candidate_ms / GESTURE_HOLD_MS),
                   int(100 * self.candidate_frames / MIN_CONFIRM_FRAMES))

    def emit(self, message, source):
        self.last_event = message
        self.last_source = source
        self.event_age_ms = 0.0

    def apply_pose(self, pose):
        if pose == "FIST":
            self.stop_height()
            self.page = (self.page + 1) % len(PAGES)
            self.enabled = True
            self.mode = "ACTIVE"
            self.emit("已选" + PAGE_NAMES[self.page] + "页", "STATIC")
            return "PAGE"
        if pose == "PALM" and PAGES[self.page] == "VOLUME":
            self.enabled = True
            self.mode = "ACTIVE"
            self.height_active = True
            self.height_filter.reset(self.volume)
            self.emit("张掌上下移动调音量", "STATIC")
            return "RESUME"
        if pose == "V_SIGN" and PAGES[self.page] == "TIMBRE":
            self.enabled = True
            self.mode = "ACTIVE"
            self.timbre = (self.timbre + 1) % len(TIMBRE_NAMES)
            self.emit("已选" + TIMBRE_NAMES[self.timbre], "STATIC")
            return "TIMBRE"
        return None

    def update_pose(self, points, elapsed_ms):
        elapsed_ms = max(0.0, float(elapsed_ms))
        self.pose = pose_kind(points)
        self.event_age_ms += elapsed_ms
        step = min(elapsed_ms, MAX_HOLD_STEP_MS)
        if self.touch_lock or self.input_mode != "GESTURE":
            # 手指触屏期间及离开后禁止手势覆盖；收手 600ms 才恢复手势。
            self.stop_height()
            self.clear_candidate()
            self.latched = None
            self.release_ms = self.lost_ms = 0.0
            if not self.touch_active and self.pose == "NONE" and elapsed_ms <= MAX_FRAME_GAP_MS:
                self.touch_release_ms += step
                if self.touch_release_ms >= LOST_RELEASE_MS:
                    self.touch_lock = False
                    self.touch_release_ms = 0.0
            else:
                self.touch_release_ms = 0.0
            return None
        if elapsed_ms > MAX_FRAME_GAP_MS:
            # 长断帧不算手势确认或释放时间，禁止按卡顿前的累计时间执行。
            self.enabled = False
            self.mode = "PAUSED"
            self.stop_height()
            self.clear_candidate()
            self.release_ms = 0.0
            self.lost_ms = 0.0
            return None

        if self.pose == "NONE":
            self.enabled = False
            self.mode = "PAUSED"
            self.stop_height()
            self.clear_candidate()
            self.release_ms = 0.0
            self.lost_ms += step
            # 一两帧检测丢失不解除锁定，避免持续握拳反复切页。
            if self.lost_ms >= LOST_RELEASE_MS:
                self.latched = None
            return None
        self.lost_ms = 0.0

        # 任意非张掌帧都立即停止连续调节；恢复须重新保持张掌确认。
        if self.pose != "PALM" or PAGES[self.page] != "VOLUME":
            self.stop_height()

        # 离散操作后必须张掌/放松或离手再触发，两个操作手势间误跳不解锁。
        if self.pose in ("PALM", "OTHER") and self.latched in ("FIST", "V_SIGN"):
            self.release_ms += step
            if self.release_ms >= RELEASE_HOLD_MS:
                self.latched = None
        else:
            self.release_ms = 0.0

        if not self.action_available(self.pose):
            self.clear_candidate()
            return None

        if self.pose != self.candidate:
            self.candidate = self.pose
            self.candidate_ms = 0.0
            self.candidate_frames = 1
        else:
            self.candidate_ms += step
            self.candidate_frames = min(MIN_CONFIRM_FRAMES, self.candidate_frames + 1)

        if self.latched == self.pose:
            if self.enabled and self.height_active:
                return self.update_height(points, step)
            return None

        if self.latched is not None:
            return None
        if self.candidate_ms < GESTURE_HOLD_MS or self.candidate_frames < MIN_CONFIRM_FRAMES:
            return None
        self.latched = self.pose
        self.release_ms = 0.0
        return self.apply_pose(self.pose)


class TouchControl:
    """LCD 坐标直接命中；一次触摸锁定一个控件，拖动不会误选音色。"""
    def __init__(self):
        self.capture = None
        self.down = False

    def update(self, control, x=None, y=None, active=False):
        control.touch_active = active
        if not active:
            self.down = False
            self.capture = None
            if control.touch_note is not None:
                control.touch_note = None
                control.emit("琴键已松开", "TOUCH_KEY")
                return "NOTE"
            return None
        control.touch_lock = True
        control.touch_release_ms = 0.0
        control.stop_height()
        control.clear_candidate()
        control.latched = None
        first = not self.down
        self.down = True
        if first or self.capture == "KEY":
            previous_capture = self.capture
            self.capture = None
            for index, (bx, by, bw, bh) in enumerate(INPUT_TABS):
                if bx <= x < bx + bw and by <= y < by + bh:
                    self.capture = "TAB"
                    control.input_mode = INPUT_MODES[index]
                    control.touch_note = None
                    control.emit("已选" + INPUT_LABELS[index], "TOUCH")
                    return "INPUT_MODE"
            self.capture = previous_capture if not first else None
        if control.input_mode == "KEYS" and self.capture in (None, "KEY"):
            note = None
            for index, (bx, by, bw, bh) in enumerate(KEY_RECTS):
                if bx <= x < bx + bw and by <= y < by + bh:
                    note = KEY_NOTES[index]
                    self.capture = "KEY"
                    break
            if note != control.touch_note:
                control.touch_note = note
                control.emit("琴键已松开" if note is None else "演奏 " + KEY_LABELS[KEY_NOTES.index(note)], "TOUCH_KEY")
                return "NOTE"
            return None
        if first:
            if control.input_mode != "TOUCH":
                return None
            for index, (bx, by, bw, bh) in enumerate(TOUCH_BUTTONS):
                if bx <= x < bx + bw and by <= y < by + bh:
                    self.capture = "BUTTON"
                    control.page = 0
                    control.timbre = index
                    control.emit("触摸选音色：" + TIMBRE_NAMES[index], "TOUCH")
                    return "TOUCH_TIMBRE"
        acquired_slider = False
        if control.input_mode == "TOUCH" and self.capture is None:
            sx, sy, sw, sh = TOUCH_SLIDER
            # 两端额外留出手指命中余量，数值仍按轨道端点映射。
            if sx - 20 <= x <= sx + sw + 20 and sy <= y < sy + sh:
                self.capture = "SLIDER"
                acquired_slider = True
        if self.capture == "SLIDER":
            sx, sy, sw, sh = TOUCH_SLIDER
            value = volume_level(100.0 * (x - sx) / sw)
            if acquired_slider or value != control.volume:
                control.page = 1
                control.volume = value
                control.height_filter.reset(value)
                control.emit("触摸音量: %d%%" % value, "TOUCH")
                return "TOUCH_VOLUME"
        return None


def poll_touch(device, touch, control):
    from machine import TOUCH
    points = device.read(1)
    if points:
        point = points[0]
        if point.event != TOUCH.EVENT_UP and point.event in (0, TOUCH.EVENT_DOWN, TOUCH.EVENT_MOVE):
            return touch.update(control, point.x, point.y, True)
    return touch.update(control)


def control_status(control):
    if control.input_mode == "KEYS":
        return "单指演奏：按住发声，松手进入尾音"
    if control.input_mode == "TOUCH":
        return "触屏页：手势不会改变参数"
    if control.touch_lock:
        return "触摸优先：收手后恢复手势"
    if control.latched in ("FIST", "V_SIGN"):
        return "已执行：张掌或收手后再操作"
    if control.pose == "V_SIGN" and PAGES[control.page] == "VOLUME":
        return "此页用张掌；握拳切回音色页"
    if control.pose == "PALM" and PAGES[control.page] == "TIMBRE":
        return "此页用剪刀手；握拳切到音量页"
    if PAGES[control.page] == "VOLUME":
        if control.height_active:
            return "正在调节：抬手增大，放低减小"
        return "张掌保持约0.5秒，开始调音量"
    return "剪刀手保持约0.5秒，切下一音色"


class ScreenPipeline:
    """保持摄像头图像引用，并显式同步 LCD 与 IDE 的合成画面。

    通道 0 YUV420SP 供屏幕视频层，通道 2 RGB888P 供 AI；叠加层供
    识别结果和页面。只初始化一次 Display，不再次调用 PipeLine.create。
    """
    def __init__(self):
        self.display_size = DISPLAY_SIZE
        self.sensor = None
        self.osd_img = None
        self.frame = None
        self.display_ready = False
        self.media_ready = False

    def create(self):
        self.sensor = Sensor()
        self.sensor.reset()
        self.sensor.set_hmirror(CAMERA_HMIRROR)
        self.sensor.set_framesize(width=DISPLAY_SIZE[0], height=DISPLAY_SIZE[1])
        self.sensor.set_pixformat(PIXEL_FORMAT_YUV_SEMIPLANAR_420)
        self.sensor.set_framesize(width=CAMERA_SIZE[0], height=CAMERA_SIZE[1], chn=CAM_CHN_ID_2)
        self.sensor.set_pixformat(PIXEL_FORMAT_RGB_888_PLANAR, chn=CAM_CHN_ID_2)
        info = self.sensor.bind_info(x=0, y=0, chn=CAM_CHN_ID_0)
        Display.bind_layer(**info, layer=Display.LAYER_VIDEO1)
        Display.init(Display.ST7701, width=DISPLAY_SIZE[0], height=DISPLAY_SIZE[1], to_ide=True)
        self.display_ready = True
        self.osd_img = image.Image(DISPLAY_SIZE[0], DISPLAY_SIZE[1], image.ARGB8888)
        MediaManager.init()
        self.media_ready = True
        self.sensor.run()

    def get_frame(self):
        self.frame = self.sensor.snapshot(chn=CAM_CHN_ID_2)
        return self.frame.to_numpy_ref()

    def show_image(self):
        Display.show_image(self.osd_img, 0, 0, Display.LAYER_OSD3)

    def destroy(self):
        if self.sensor is not None:
            try:
                self.sensor.stop()
            except Exception as error:
                print("Cleanup sensor:", error)
        self.frame = self.osd_img = None
        if self.display_ready:
            try:
                Display.deinit()
            except Exception as error:
                print("Cleanup display:", error)
        os.exitpoint(os.EXITPOINT_ENABLE_SLEEP)
        time.sleep_ms(100)
        if self.media_ready:
            MediaManager.deinit()


def draw_overlay_text(canvas, x, y, size, text, color):
    # 默认只绘一次；需要阴影时可启用，但会增加中文字体绘制开销。
    if TEXT_SHADOW:
        canvas.draw_string_advanced(x + 1, y + 1, size, text, color=(255, 0, 0, 0))
    canvas.draw_string_advanced(x, y, size, text, color=color)


def draw_page_frame(pl, box, points, control, fps):
    canvas = pl.osd_img
    # clear 只清透明 OSD 层；完整摄像头视频由 VIDEO1 层直接显示。
    canvas.clear()
    w, h = pl.display_size
    white, green, yellow = (255, 255, 255, 255), (255, 0, 255, 130), (255, 255, 220, 0)
    if box is not None:
        x1, y1 = screen_xy(float(box[2]), float(box[3]), pl.display_size)
        x2, y2 = screen_xy(float(box[4]), float(box[5]), pl.display_size)
        canvas.draw_rectangle(x1, y1, max(1, x2 - x1), max(1, y2 - y1), color=green, thickness=2)
    if palm_geometry(points) is not None:
        coords = [screen_xy(points[i * 2], points[i * 2 + 1], pl.display_size) for i in range(21)]
        for finger in range(5):
            previous = 0
            for joint in range(1 + finger * 4, 5 + finger * 4):
                canvas.draw_line(coords[previous][0], coords[previous][1], coords[joint][0],
                                 coords[joint][1], color=(255, 120, 170, 210), thickness=1)
                previous = joint
        for x, y in coords:
            canvas.draw_circle(x, y, 3, color=white, fill=True)

    draw_overlay_text(canvas, 8, 4, 22, "K230 触摸控制 V4.9", white)
    draw_overlay_text(canvas, w - 155, 7, 18,
                      "触摸优先" if control.input_mode != "GESTURE" else "AI FPS: %.1f" % fps, white)
    for index, (bx, by, bw, bh) in enumerate(INPUT_TABS):
        color = yellow if control.input_mode == INPUT_MODES[index] else white
        canvas.draw_rectangle(bx, by, bw, bh, color=color,
                              thickness=4 if control.input_mode == INPUT_MODES[index] else 2)
        draw_overlay_text(canvas, bx + 40, by + 20, 32, INPUT_LABELS[index], color)
    text = "%s页 音量%d%% %s %d/%d" % (
        PAGE_NAMES[control.page], control.volume, TIMBRE_NAMES[control.timbre],
        control.timbre + 1, len(TIMBRE_NAMES))
    draw_overlay_text(canvas, 8, 118, 24, text, yellow)
    pose_text = "识别: " + POSE_LABELS[control.pose]
    progress = control.confirm_progress()
    if progress > 0:
        pose_text += "  确认: %d%%" % progress
    elif control.height_active:
        pose_text += "  高度控制中"
    elif control.latched == control.pose:
        pose_text += "  已执行"
    if control.input_mode == "GESTURE":
        draw_overlay_text(canvas, 8, 148, 20, pose_text, green)
    link_text = "串口已发%d条（无回读）" % control.tx_count if control.link_active else "屏幕演示：串口未启用"
    draw_overlay_text(canvas, 8, 176, 18, link_text, white)

    draw_overlay_text(canvas, 8, 202, 18, control_status(control), yellow)
    if control.event_age_ms < 1800:
        draw_overlay_text(canvas, 8, 228, 18, control.last_event, white)
    if control.input_mode == "KEYS":
        for index, (bx, by, bw, bh) in enumerate(KEY_RECTS):
            color = yellow if control.touch_note == KEY_NOTES[index] else white
            canvas.draw_rectangle(bx, by, bw, bh, color=color,
                                  thickness=4 if control.touch_note == KEY_NOTES[index] else 2)
            draw_overlay_text(canvas, bx + 18, by + 22, 28,
                              "%d %s" % (index + 1, KEY_LABELS[index]), color)
        draw_overlay_text(canvas, 8, 454, 18, "声音由FPGA输出；音色/音量在第2页设置", white)
        return
    if control.input_mode == "GESTURE":
        draw_overlay_text(canvas, 20, 330, 22, "握拳：切换音色 / 音量模式", white)
        draw_overlay_text(canvas, 20, 366, 22, "音色模式：剪刀手循环切换音色", white)
        draw_overlay_text(canvas, 20, 402, 22, "音量模式：张掌抬高增大、放低减小", white)
        hint = "点击顶部标签进入触屏控制" if control.touch_ready else "触摸未启用：请检查终端错误"
        draw_overlay_text(canvas, 8, 454, 18, hint, white)
        return
    for index, (bx, by, bw, bh) in enumerate(TOUCH_BUTTONS):
        color = yellow if index == control.timbre else white
        canvas.draw_rectangle(bx, by, bw, bh, color=color,
                              thickness=3 if index == control.timbre else 1)
        draw_overlay_text(canvas, bx + 60, by + 20, 32, TIMBRE_NAMES[index], color)
    draw_overlay_text(canvas, 20, 354, 24, "音量 %d%%（拖动，每档5%%）" % control.volume, yellow)
    sx, sy, sw, sh = TOUCH_SLIDER
    cy = sy + sh // 2
    canvas.draw_rectangle(sx - 20, sy, sw + 40, sh, color=white, thickness=2)
    canvas.draw_line(sx, cy, sx + sw, cy, color=white, thickness=8)
    knob = sx + int(sw * control.volume / 100)
    if knob > sx:
        canvas.draw_line(sx, cy, knob, cy, color=yellow, thickness=8)
    canvas.draw_circle(knob, cy, 20, color=yellow, fill=True)
    hint = "点击音色 / 拖动音量；手势已暂停" if control.touch_ready else "触摸未启用：请检查终端错误"
    draw_overlay_text(canvas, 8, 454, 18, hint, white)


def main(fpga_link=None):
    pl, detector, keypoints = None, None, None
    stage = "check model files"
    try:
        os.exitpoint(os.EXITPOINT_ENABLE)
        paths = find_music_models()
        print(BUILD_TAG, "Models:", paths)
        print("FIST cycles pages. V_SIGN cycles piano/guitar/bell on TIMBRE page.")
        print("PALM height changes volume on VOLUME page. Open/relax or withdraw to rearm.")
        print("Screen simulation only." if fpga_link is None else "FPGA UART parameter control enabled.")
        control = PageControl()
        if fpga_link is not None:
            fpga_link.attach(control)
            control.link_active = True
        stage = "create camera, LCD and IDE display"
        pl = ScreenPipeline()
        pl.create()
        touch = TouchControl()
        touch_device = None
        try:
            from machine import TOUCH
            touch_device = TOUCH(0)
            control.touch_ready = True
            print("TOUCH(0) enabled: LCD coordinates 640x480; camera mirror OFF.")
        except Exception as error:
            print("Touch init failed; gestures remain available:", error)
        draw_page_frame(pl, None, None, control, 0)
        pl.show_image()
        stage = "load hand detector"
        detector = HandDetector(paths[0])
        detector.config_preprocess()
        stage = "load hand keypoints"
        keypoints = HandKeypoints(paths[1])
        previous_ms = last_report_ms = last_gc_ms = time.ticks_ms()
        last_draw_ms = previous_ms
        last_draw_state = None
        timing_totals = [0.0] * 8
        timing_frames = 0
        timing_frame_us = 0
        measured_fps = 0.0
        stage = "palm height and static gesture control loop"
        while True:
            os.exitpoint()
            t0 = time.ticks_us()
            # 先读触摸再做耗时工作；切到触屏页当轮就停止推理。
            touch_event = poll_touch(touch_device, touch, control) if touch_device is not None else None
            run_ai = control.input_mode == "GESTURE" and touch_event != "INPUT_MODE"
            # VIDEO1 由硬件持续送屏，触屏页不必 snapshot AI 通道。
            frame = pl.get_frame() if run_ai else None
            t1 = time.ticks_us()
            box = choose_hand(detector.run(frame)) if run_ai else None
            t2 = time.ticks_us()
            points = None
            t3 = t4 = t2
            if box is not None:
                keypoints.config_preprocess(box)
                t3 = time.ticks_us()
                points = keypoints.run(frame)
                t4 = time.ticks_us()
            now_ms = time.ticks_ms()
            gesture_event = control.update_pose(points, time.ticks_diff(now_ms, previous_ms))
            event = touch_event if touch_event is not None else gesture_event
            previous_ms = now_ms
            if fpga_link is not None:
                if fpga_link.publish(control, event):
                    if event not in ("NOTE", "INPUT_MODE"):
                        control.emit("已发音量%d%%" % control.volume if event in ("VOLUME", "TOUCH_VOLUME")
                                     else "已发音色：" + TIMBRE_NAMES[control.timbre], "UART_TX")
                fpga_link.keepalive(now_ms)
                control.tx_count = fpga_link.sent_commands
            # 连续音量不逐帧打印，统一在每两秒摘要中报告。
            if event is not None and event not in ("VOLUME", "TOUCH_VOLUME"):
                print("CONTROL EVENT:", event, "source", control.last_source,
                      "page", PAGES[control.page], "timbre", control.timbre + 1, "volume", control.volume)
            t5 = time.ticks_us()
            # 触摸采样与 UI 更新分开：值变化才重画，滑动最多每 50ms 重画一次。
            # 待显示状态每轮重算，即使松手也会补画最后一档，命令不等重画。
            draw_state = (control.input_mode, control.page, control.timbre, control.volume,
                          control.tx_count, control.touch_note, control.last_event if control.event_age_ms < 1800 else None)
            redraw = (control.input_mode == "GESTURE" or event in ("INPUT_MODE", "TOUCH_TIMBRE", "NOTE")
                      or draw_state != last_draw_state
                      and time.ticks_diff(now_ms, last_draw_ms) >= TOUCH_REDRAW_MS)
            if redraw:
                draw_page_frame(pl, box, points, control, measured_fps)
            t6 = time.ticks_us()
            if redraw:
                pl.show_image()
                last_draw_state = draw_state
                last_draw_ms = now_ms
            t7 = time.ticks_us()
            del frame
            gc_interval = 2000 if control.input_mode != "GESTURE" else 500
            gc_age = time.ticks_diff(now_ms, last_gc_ms)
            if gc_age >= gc_interval and (not control.touch_active or gc_age >= 5000):
                gc.collect()
                last_gc_ms = now_ms
            time.sleep_ms(TOUCH_POLL_MS if control.input_mode != "GESTURE" else 1)
            t8 = time.ticks_us()
            boundaries = (t0, t1, t2, t3, t4, t5, t6, t7, t8)
            for index in range(8):
                timing_totals[index] += time.ticks_diff(boundaries[index + 1], boundaries[index])
            timing_frame_us += time.ticks_diff(t8, t0)
            timing_frames += 1
            report_ms = time.ticks_ms()
            window_ms = time.ticks_diff(report_ms, last_report_ms)
            if window_ms >= PERF_REPORT_MS:
                measured_fps = timing_frames * 1000.0 / window_ms
                divisor = timing_frames * 1000.0
                average = tuple(value / divisor for value in timing_totals)
                print("PERF loop Hz: %.1f; avg ms cam %.1f det %.1f crop %.1f kp %.1f ctrl %.1f draw %.1f show %.1f gc+wait %.1f" % ((measured_fps,) + average))
                print("STATE pose", control.pose, "page", PAGES[control.page],
                      "volume", control.volume, "timbre", control.timbre + 1,
                      "height_active", control.height_active, "palm_y", control.height_y,
                      "target", control.height_target, "avg loop ms", timing_frame_us / divisor)
                timing_totals = [0.0] * 8
                timing_frame_us = timing_frames = 0
                last_report_ms = report_ms
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
