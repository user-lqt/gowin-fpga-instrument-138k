"""Host regression checks for AI2D crop reuse; no KPU execution."""
import ast
import math
from pathlib import Path
from types import SimpleNamespace
import unittest


PATH = Path(__file__).with_name("gesture_page_control_test.py")


class FakeAi2d:
    def __init__(self, *_):
        self.builds = 0
        self.current_crop = None

    def set_ai2d_dtype(self, *_):
        pass

    def crop(self, *crop):
        self.current_crop = crop

    def resize(self, *_):
        pass

    def build(self, *_):
        self.builds += 1


class FakeAIBase:
    def __init__(self, *_):
        pass


class KeypointOutput:
    def __init__(self, values):
        self.values = values

    def reshape(self, _):
        return self.values


def create_keypoints():
    tree = ast.parse(PATH.read_text(encoding="utf-8"))
    nodes = [node for node in tree.body if isinstance(node, ast.Assign)
             or isinstance(node, ast.ClassDef) and node.name == "HandKeypoints"]
    namespace = {
        "math": math, "AIBase": FakeAIBase, "Ai2d": FakeAi2d,
        "np": SimpleNamespace(uint8="uint8"),
        "nn": SimpleNamespace(ai2d_format=SimpleNamespace(NCHW_FMT=0),
                              interp_method=SimpleNamespace(tf_bilinear=0),
                              interp_mode=SimpleNamespace(half_pixel=0)),
    }
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(PATH), "exec"), namespace)
    return namespace["HandKeypoints"]("host-test-model")


class PreprocessCacheTests(unittest.TestCase):
    def test_unchanged_crop_reuses_graph_and_preserves_keypoint_mapping(self):
        kp = create_keypoints()
        box = [0, 0.9, 100, 100, 300, 300]
        self.assertTrue(kp.config_preprocess(box))
        crop = list(kp.crop)
        output = [KeypointOutput([0.25, 0.75] * 21)]
        expected = kp.postprocess(output)
        for _ in range(20):
            self.assertFalse(kp.config_preprocess(box))
            self.assertEqual(kp.postprocess(output), expected)
        self.assertEqual(kp.ai2d.builds, 1)
        self.assertEqual(expected[:2], [crop[0] + 0.25 * crop[2], crop[1] + 0.75 * crop[3]])

    def test_moving_hand_rebuilds_graph_and_edge_crop_uses_matching_coordinates(self):
        kp = create_keypoints()
        kp.config_preprocess([0, 0.9, 100, 100, 300, 300])
        previous = list(kp.crop)
        self.assertTrue(kp.config_preprocess([0, 0.9, 0, 0, 100, 200]))
        self.assertNotEqual(kp.crop, previous)
        self.assertEqual(kp.ai2d.builds, 2)
        self.assertEqual(tuple(kp.crop), kp.ai2d.current_crop)
        self.assertNotEqual(kp.crop[2], kp.crop[3])
        values = kp.postprocess([KeypointOutput([0.25, 0.75] * 21)])
        x, y, width, height = kp.crop
        self.assertEqual(values[:2], [x + 0.25 * width, y + 0.75 * height])
        self.assertFalse(kp.config_preprocess([0, 0.9, 0, 0, 100, 200]))
        self.assertEqual(kp.ai2d.builds, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
