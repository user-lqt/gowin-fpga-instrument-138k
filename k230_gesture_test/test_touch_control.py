"""Touch -> standalone program -> UART regression checks; no hardware needed."""
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from test_single_file import load_single_file
from test_static_control_logic import pose, palm_at_target


class TouchTests(unittest.TestCase):
    def setUp(self):
        self.ns = load_single_file()
        self.c = self.ns['PageControl']()
        self.t = self.ns['TouchControl']()
        self.frames = []
        self.link = self.ns['FpgaLink'](SimpleNamespace(send=self.frames.append))
        self.link.attach(self.c)

    def press(self, x, y):
        event = self.t.update(self.c, x, y, True)
        self.link.publish(self.c, event)
        return event

    def release(self):
        self.t.update(self.c)

    def enter_touch(self):
        self.assertEqual(self.press(320, 60), 'INPUT_MODE')
        self.release()
        self.assertEqual(self.c.input_mode, 'TOUCH')
        self.assertEqual(self.frames, [])

    def test_buttons_send_correct_ids_and_explicit_reselect(self):
        self.enter_touch()
        for index, x in enumerate((110, 320, 530)):
            self.assertEqual(self.press(x, 325), 'TOUCH_TIMBRE')
            for _ in range(10):
                self.assertIsNone(self.press(x, 325))
            self.release()
            self.assertEqual(self.frames[-1], self.ns['make_frame'](0xB5, index))
        self.press(530, 325)
        self.assertEqual(len(self.frames), 4)

    def test_slider_steps_clamp_capture_and_no_repeated_writes(self):
        self.enter_touch()
        self.press(320, 420)  # Explicitly resend initial 50%.
        self.assertEqual(self.frames[-1][2], 50)
        self.press(600, 420)
        self.assertEqual(self.c.volume, 100)
        self.press(900, 200)  # Captured slider clamps outside its rectangle.
        self.assertEqual(len(self.frames), 2)
        self.press(-100, 325)
        self.assertEqual(self.c.volume, 0)
        self.assertEqual(self.c.timbre, 0)
        for x in range(40, 601, 7):
            self.press(x, 420)
        self.assertTrue(all(f[1] == 0xB4 and f[2] % 5 == 0 for f in self.frames))
        self.release()
        count = len(self.frames)
        self.release()
        self.assertEqual(len(self.frames), count)

    def test_button_drag_and_outside_start_do_not_activate_other_controls(self):
        self.enter_touch()
        self.press(320, 325)
        self.press(530, 325)
        self.press(40, 420)
        self.assertEqual((self.c.timbre, self.c.volume), (1, 50))
        self.release()
        self.press(5, 250)
        self.press(530, 325)
        self.assertEqual(len(self.frames), 1)

    def test_pages_isolate_inputs_and_return_requires_withdrawal(self):
        self.press(530, 325)  # Hidden touch controls cannot act on gesture page.
        self.release()
        self.assertEqual(self.frames, [])
        self.enter_touch()
        for points in (pose('FIST'), pose('V_SIGN'), palm_at_target(100), None):
            for _ in range(30):
                self.assertIsNone(self.c.update_pose(points, 100))
        self.assertEqual((self.c.timbre, self.c.volume), (0, 50))
        self.press(100, 60)
        self.release()
        self.assertEqual(self.c.input_mode, 'GESTURE')
        for _ in range(30):
            self.assertIsNone(self.c.update_pose(pose('V_SIGN'), 100))
        for _ in range(7):
            self.c.update_pose(None, 100)
        events = [self.c.update_pose(pose('V_SIGN'), 100) for _ in range(7)]
        self.assertIn('TIMBRE', events)

    def test_slide_in_from_blank_area_acquires_slider_only(self):
        self.enter_touch()
        self.assertIsNone(self.press(320, 260))
        self.assertEqual(self.press(320, 415), 'TOUCH_VOLUME')
        self.assertEqual(self.frames[-1][2], 50)
        self.assertIsNone(self.press(320, 415))
        self.assertEqual(self.press(600, 415), 'TOUCH_VOLUME')
        self.assertEqual(self.frames[-1][2], 100)

    def enter_keys(self):
        self.assertEqual(self.press(530, 60), 'INPUT_MODE')
        self.release()
        self.assertEqual(self.c.input_mode, 'KEYS')

    def test_all_eight_keys_send_press_and_release(self):
        self.enter_keys()
        for note, (x, y, w, h) in zip(self.ns['KEY_NOTES'], self.ns['KEY_RECTS']):
            self.assertEqual(self.press(x + w // 2, y + h // 2), 'NOTE')
            for _ in range(10):
                self.assertIsNone(self.press(x + w // 2, y + h // 2))
            event = self.t.update(self.c)
            self.link.publish(self.c, event)
            self.assertEqual(self.frames[-2:], [self.ns['make_note_frame'](0x90, note, 100),
                                               self.ns['make_note_frame'](0x80, note)])
        self.assertEqual(len(self.frames), 16)

    def test_key_slide_releases_before_new_note_and_on_exit(self):
        self.enter_keys()
        self.press(80, 300)
        self.press(240, 300)
        self.assertEqual([(f[1], f[2]) for f in self.frames], [(0x90, 60), (0x80, 60), (0x90, 62)])
        self.press(240, 250)  # Outside keys releases, but allows sliding back in.
        self.assertEqual(self.frames[-1][1:3], bytes((0x80, 62)))
        self.press(400, 390)
        self.press(320, 60)  # Slide onto a tab: release before leaving the page.
        self.assertEqual(self.c.input_mode, 'TOUCH')
        self.assertEqual(self.frames[-1][1:3], bytes((0x80, 71)))
        self.assertIsNone(self.link.active_note)

    def test_keepalive_does_not_retrigger_and_cleanup_releases(self):
        self.enter_keys()
        self.press(80, 300)
        with patch.dict(sys.modules, {'time': SimpleNamespace(ticks_diff=lambda a, b: a-b)}):
            for now in (0, 100, 249, 250, 300, 500):
                self.link.keepalive(now)
        self.assertEqual([f[1] for f in self.frames], [0x90, 0xB6, 0xB6])
        closed = []
        self.link.transport.deinit = lambda: closed.append(True)
        self.link.deinit()
        self.assertEqual(self.frames[-1], self.ns['make_note_frame'](0x80, 60))
        self.assertEqual(closed, [True])

    def test_note_protocol_validation_and_write_failure_cleanup(self):
        for args in ((0x90, 128, 100), (0x90, 60, 128), (0x80, 60, 1), (0xB6, -1, 0)):
            with self.assertRaises(ValueError):
                self.ns['make_note_frame'](*args)
        self.link.transport.send = lambda frame: 2
        with self.assertRaises(OSError):
            self.link.set_note(60)
        self.assertEqual(self.link.active_note, 60)
        self.link.transport.send = self.frames.append
        self.link.set_note(None)
        self.assertEqual(self.frames[-1], self.ns['make_note_frame'](0x80, 60))

    def test_touch_main_loop_skips_camera_and_ai_and_flushes_final_value(self):
        calls = []
        clock = [0]
        loops = [0]
        api = SimpleNamespace(EVENT_DOWN=1, EVENT_MOVE=2, EVENT_UP=3)
        samples = [(320, 60, 1), (320, 60, 3), (40, 415, 1),
                   (600, 415, 2), (600, 415, 3)]
        def read(count):
            calls.append('touch')
            if samples:
                x, y, event = samples.pop(0)
                return [SimpleNamespace(x=x, y=y, event=event)]
            return []
        def touch_factory(index):
            return SimpleNamespace(read=read)
        for name in ('EVENT_DOWN', 'EVENT_MOVE', 'EVENT_UP'):
            setattr(touch_factory, name, getattr(api, name))
        def exitpoint(*args):
            if not args:
                loops[0] += 1
                if loops[0] > 30:
                    raise KeyboardInterrupt()
        def unexpected(*args):
            self.fail('Touch page must not snapshot camera or run AI')
        pl = SimpleNamespace(create=lambda: None, get_frame=unexpected,
                             show_image=lambda: calls.append('show'), destroy=lambda: None)
        ai = SimpleNamespace(config_preprocess=lambda: None, run=unexpected)
        draws = []
        self.ns.update(
            os=SimpleNamespace(exitpoint=exitpoint, EXITPOINT_ENABLE=1),
            time=SimpleNamespace(ticks_ms=lambda: clock[0], ticks_us=lambda: clock[0] * 1000,
                                 ticks_diff=lambda a, b: a - b,
                                 sleep_ms=lambda ms: clock.__setitem__(0, clock[0] + ms)),
            gc=SimpleNamespace(collect=lambda: None), print=lambda *args: None,
            find_music_models=lambda: ('det', 'kp'), ScreenPipeline=lambda: pl,
            HandDetector=lambda path: ai, HandKeypoints=lambda path: ai,
            draw_page_frame=lambda pipeline, box, pts, c, fps: draws.append((c.input_mode, c.volume)),
            release=lambda *args: None)
        with patch.dict(sys.modules, {'machine': SimpleNamespace(TOUCH=touch_factory)}):
            self.ns['main'](fpga_link=self.link)
        self.assertEqual(calls.count('touch'), 30)
        self.assertLess(calls.count('show'), 8)
        self.assertEqual(draws[-1], ('TOUCH', 100))
        self.assertEqual([f[2] for f in self.frames], [0, 100])

    def test_hardware_touch_events_and_empty_release(self):
        self.enter_touch()
        api = SimpleNamespace(EVENT_DOWN=1, EVENT_MOVE=2, EVENT_UP=3)
        samples = [[SimpleNamespace(x=40, y=420, event=1)],
                   [SimpleNamespace(x=600, y=420, event=2)],
                   [SimpleNamespace(x=600, y=420, event=3)], [],
                   [SimpleNamespace(x=320, y=420, event=0)]]
        device = SimpleNamespace(read=lambda count: samples.pop(0))
        with patch.dict(sys.modules, {'machine': SimpleNamespace(TOUCH=api)}):
            events = [self.ns['poll_touch'](device, self.t, self.c) for _ in range(5)]
        self.assertEqual(events, ['TOUCH_VOLUME', 'TOUCH_VOLUME', None, None, 'TOUCH_VOLUME'])

    def test_both_pages_keep_camera_transparent_and_text_inside_screen(self):
        texts = []
        class Canvas:
            def __getattr__(self, name):
                def call(*args, **kwargs):
                    if name == 'draw_rectangle':
                        assert not kwargs.get('fill', False)
                    if name == 'draw_string_advanced':
                        x, y, size, text = args
                        assert 0 <= y <= 480 - size
                        assert 0 <= x and x + sum(size if ord(c) > 127 else size * .65 for c in text) <= 640
                        texts.append(text)
                return call
        pipeline = SimpleNamespace(osd_img=Canvas(), display_size=[640, 480])
        for mode in ('GESTURE', 'TOUCH', 'KEYS'):
            self.c.input_mode = mode
            for volume in (0, 50, 100):
                self.c.volume = volume
                self.ns['draw_page_frame'](pipeline, None, None, self.c, 10)
        self.assertIn('1 手势', texts)
        self.assertIn('2 调参', texts)


if __name__ == '__main__':
    unittest.main()
