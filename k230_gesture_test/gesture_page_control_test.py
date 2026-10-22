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
BUILD_TAG = "PALM HEIGHT V4.4"
TEXT_SHADOW = False
PERF_REPORT_MS = 2000
TIMBRE_NAMES = ("钢琴", "吉他", "编钟")
PAGES = ("TIMBRE", "VOLUME")
PAGE_NAMES = ("音色", "音量")
POSE_LABELS = {"ONE": "单指", "V_SIGN": "剪刀手", "INCREASE": "点赞",
               "DECREASE": "三指", "PALM": "张掌", "FIST": "握拳",
               "OTHER": "未识别", "NONE": "无手"}
INITIAL_VOLUME = 50
GESTURE_HOLD_MS = 350
PAUSE_HOLD_MS = 200
RELEASE_HOLD_MS = 250
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
    # 三指伸直、小指收拢；拇指姿态不限，无需翻转手腕。
    if index < 49 and middle < 49 and ring < 49 and pinky > 65:
        return "DECREASE"
    if index < 49 and middle < 49 and ring > 65 and pinky > 65:
        return "V_SIGN"
    if index < 49 and middle > 65 and ring > 65 and pinky > 65:
        return "ONE"
    if all(angle < 49 for angle in angles[1:]):
        return "PALM"
    if all(angle > 65 for angle in angles[1:]):
        # 点赞为四指收拢、拇指向画面上方伸直。
        dx, dy = points[8] - points[4], points[9] - points[5]
        part1 = math.sqrt((points[6] - points[4]) ** 2 + (points[7] - points[5]) ** 2)
        part2 = math.sqrt((points[8] - points[6]) ** 2 + (points[9] - points[7]) ** 2)
        straight = math.sqrt(dx * dx + dy * dy) >= 0.85 * (part1 + part2) and part1 + part2 > 1
        outside = math.sqrt((points[8] - points[10]) ** 2 + (points[9] - points[11]) ** 2) >= geometry[2] * 0.40
        vertical = abs(dy) >= max(12.0, geometry[2] * 0.32) and abs(dy) >= abs(dx) * 1.10
        if thumb < 49 and straight and outside and vertical and dy < 0:
            return "INCREASE"
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
    """选页与音色保持确认；仅音量页确认张掌后按高度连续调节。"""
    def __init__(self):
        self.page = self.timbre = 0
        self.volume = INITIAL_VOLUME
        self.enabled = False
        self.mode = "PAUSED"
        self.pose = "NONE"
        self.candidate = None
        self.candidate_ms = 0.0
        self.candidate_frames = 0
        self.latched = None
        self.release_ms = 0.0
        self.height_filter = HeightVolumeFilter(self.volume)
        self.height_active = False
        self.height_y = None
        self.height_target = None
        self.event_age_ms = 2000.0
        self.last_event = "单指选音量，剪刀手选音色"
        self.last_source = None

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
        if self.candidate is None or self.candidate == self.latched:
            return 0
        needed = PAUSE_HOLD_MS if self.candidate == "FIST" else GESTURE_HOLD_MS
        return min(100, int(100 * self.candidate_ms / needed),
                   int(100 * self.candidate_frames / MIN_CONFIRM_FRAMES))

    def emit(self, message, source):
        self.last_event = message
        self.last_source = source
        self.event_age_ms = 0.0

    def adjust(self, increase):
        if not self.enabled or PAGES[self.page] != "TIMBRE":
            return None
        change = 1 if increase else -1
        previous = self.timbre
        self.timbre = max(0, min(len(TIMBRE_NAMES) - 1, self.timbre + change))
        self.emit(("已是" if previous == self.timbre else "已选") + TIMBRE_NAMES[self.timbre], "STATIC")
        return "INCREASE" if increase else "DECREASE"

    def apply_pose(self, pose):
        if pose in ("ONE", "V_SIGN"):
            self.stop_height()
            self.page = 1 if pose == "ONE" else 0
            self.enabled = True
            self.mode = "ACTIVE"
            self.emit("已选" + PAGE_NAMES[self.page] + "页", "STATIC")
            return "PAGE"
        if pose == "PALM":
            self.enabled = True
            self.mode = "ACTIVE"
            self.height_active = PAGES[self.page] == "VOLUME"
            self.height_filter.reset(self.volume)
            message = "张掌上下移动调音量" if self.height_active else "已启用音色控制"
            self.emit(message, "STATIC")
            return "RESUME"
        if pose == "FIST":
            self.stop_height()
            self.enabled = False
            self.mode = "PAUSED"
            self.emit("已暂停，张掌或选页恢复", "STATIC")
            return "PAUSE"
        if pose in ("INCREASE", "DECREASE"):
            return self.adjust(pose == "INCREASE")
        return None

    def update_pose(self, points, elapsed_ms):
        elapsed_ms = max(0.0, float(elapsed_ms))
        self.pose = pose_kind(points)
        self.event_age_ms += elapsed_ms
        step = min(elapsed_ms, MAX_HOLD_STEP_MS)
        if self.pose == "NONE" or elapsed_ms > MAX_FRAME_GAP_MS:
            # 手丢失或长时间断帧立即暂停；重新选页/张掌恢复。
            self.enabled = False
            self.mode = "PAUSED"
            self.stop_height()
            self.clear_candidate()
            self.latched = None
            self.release_ms = 0.0
            return None

        # 任意非张掌帧都立即停止连续调节；恢复须重新保持张掌确认。
        if self.pose != "PALM" or PAGES[self.page] != "VOLUME":
            self.stop_height()

        if self.pose != self.latched:
            self.release_ms += step
            if self.release_ms >= RELEASE_HOLD_MS:
                self.latched = None
        else:
            self.release_ms = 0.0

        if self.pose == "OTHER":
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

        needed = PAUSE_HOLD_MS if self.pose == "FIST" else GESTURE_HOLD_MS
        if self.candidate_ms < needed or self.candidate_frames < MIN_CONFIRM_FRAMES:
            return None
        # 暂停状态下不接受加减，也不锁存它；选页/张掌能恢复。
        if not self.enabled and self.pose in ("INCREASE", "DECREASE"):
            return None
        self.latched = self.pose
        self.release_ms = 0.0
        return self.apply_pose(self.pose)


def control_status(control):
    if not control.enabled:
        return "已暂停：单指或剪刀手选页"
    if PAGES[control.page] == "VOLUME":
        if control.height_active:
            return "正在调节：抬手增大，放低减小"
        return "张掌保持约0.4秒，开始调音量"
    return "保持手势片刻即可操作"


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
        self.sensor.set_hmirror(True)
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

    draw_overlay_text(canvas, 8, 4, 22, "K230 高度音量 V4.4", white)
    draw_overlay_text(canvas, w - 155, 7, 18, "AI FPS: %.1f" % fps, white)
    text = "%s页 音量%d%% %s %d/%d" % (
        PAGE_NAMES[control.page], control.volume, TIMBRE_NAMES[control.timbre],
        control.timbre + 1, len(TIMBRE_NAMES))
    draw_overlay_text(canvas, 8, 34, 24, text, yellow)
    pose_text = "识别: " + POSE_LABELS[control.pose]
    progress = control.confirm_progress()
    if progress > 0:
        pose_text += "  确认: %d%%" % progress
    elif control.height_active:
        pose_text += "  高度控制中"
    elif control.latched == control.pose:
        pose_text += "  已确认"
    draw_overlay_text(canvas, 8, 66, 20, pose_text, green)

    draw_overlay_text(canvas, 8, h - 110, 20, control_status(control), yellow)
    if control.height_active and control.height_y is not None:
        detail = "掌心Y: %.0f  目标档: %d%%" % (control.height_y, volume_level(control.height_target))
    elif control.event_age_ms < 1800:
        detail = control.last_event
    else:
        detail = "张掌确认后按高度调音量" if PAGES[control.page] == "VOLUME" else "音色手势保持约0.4秒"
    draw_overlay_text(canvas, 8, h - 84, 20, detail, white)
    draw_overlay_text(canvas, 8, h - 58, 20, "单指音量 / 剪刀手音色 / 握拳暂停", white)
    hint = "张掌抬高增大 / 放低减小 / 收手保持" if PAGES[control.page] == "VOLUME" else "点赞下一音色 / 三指上一音色 / 张掌恢复"
    draw_overlay_text(canvas, 8, h - 32, 20, hint, white)


def main(fpga_link=None):
    pl, detector, keypoints = None, None, None
    stage = "check model files"
    try:
        os.exitpoint(os.EXITPOINT_ENABLE)
        paths = find_music_models()
        print(BUILD_TAG, "Models:", paths)
        print("ONE volume page; hold PALM then raise/lower palm to set volume.")
        print("V_SIGN timbre page; THUMB UP next; THREE FINGERS previous; FIST pause.")
        print("Screen simulation only." if fpga_link is None else "FPGA UART parameter control enabled.")
        control = PageControl()
        if fpga_link is not None:
            fpga_link.attach(control)
        stage = "create camera, LCD and IDE display"
        pl = ScreenPipeline()
        pl.create()
        draw_page_frame(pl, None, None, control, 0)
        pl.show_image()
        stage = "load hand detector"
        detector = HandDetector(paths[0])
        detector.config_preprocess()
        stage = "load hand keypoints"
        keypoints = HandKeypoints(paths[1])
        previous_ms = last_report_ms = last_gc_ms = time.ticks_ms()
        timing_totals = [0.0] * 8
        timing_frames = 0
        timing_frame_us = 0
        measured_fps = 0.0
        stage = "palm height and static gesture control loop"
        while True:
            os.exitpoint()
            t0 = time.ticks_us()
            frame = pl.get_frame()
            t1 = time.ticks_us()
            box = choose_hand(detector.run(frame))
            t2 = time.ticks_us()
            points = None
            t3 = t4 = t2
            if box is not None:
                keypoints.config_preprocess(box)
                t3 = time.ticks_us()
                points = keypoints.run(frame)
                t4 = time.ticks_us()
            now_ms = time.ticks_ms()
            event = control.update_pose(points, time.ticks_diff(now_ms, previous_ms))
            previous_ms = now_ms
            if fpga_link is not None:
                fpga_link.publish(control, event)
            # 连续音量不逐帧打印，统一在每两秒摘要中报告。
            if event is not None and event != "VOLUME":
                print("CONTROL EVENT:", event, "source", control.last_source,
                      "page", PAGES[control.page], "timbre", control.timbre + 1, "volume", control.volume)
            t5 = time.ticks_us()
            draw_page_frame(pl, box, points, control, measured_fps)
            t6 = time.ticks_us()
            pl.show_image()
            t7 = time.ticks_us()
            del frame
            if time.ticks_diff(now_ms, last_gc_ms) >= 500:
                gc.collect()
                last_gc_ms = now_ms
            time.sleep_ms(1)
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
                print("PERF AI FPS: %.1f; avg ms cam %.1f det %.1f crop %.1f kp %.1f ctrl %.1f draw %.1f show %.1f gc+wait %.1f" % ((measured_fps,) + average))
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
