import copy
import unittest

from editor_acceptance_captions import caption_snapshot, unchanged_captions


class CaptionContractTests(unittest.TestCase):
    def report(self):
        return {"version": 1, "captions": [{
            "id": "synthetic-caption", "clock": "output", "content": "Synthetic beat",
            "anchor": {
                "start": {"frame": 12, "frameRate": {"numerator": 60000, "denominator": 1001}, "markerID": "beat-first"},
                "end": {"frame": 24, "frameRate": {"numerator": 60, "denominator": 1}, "markerID": "beat-next"},
            }, "startSeconds": 12012 / 60000, "endSeconds": 24 / 60,
        }]}

    def test_mixed_rates_and_text_update_preserve_exact_times(self):
        report = self.report()
        before = caption_snapshot(report)
        report["captions"][0]["content"] = "Revised synthetic text"
        unchanged_captions(before, report)
        self.assertEqual(before["synthetic-caption"][0].numerator, 1001)
        self.assertEqual(before["synthetic-caption"][0].denominator, 5000)

    def test_frame_movement_and_provenance_loss_are_rejected(self):
        report = self.report()
        before = caption_snapshot(report)
        shifted = copy.deepcopy(report)
        shifted["captions"][0]["anchor"]["end"]["frame"] = 25
        shifted["captions"][0]["endSeconds"] = 25 / 60
        with self.assertRaisesRegex(RuntimeError, "rational times"):
            unchanged_captions(before, shifted)
        del report["captions"][0]["anchor"]["start"]["markerID"]
        with self.assertRaisesRegex(RuntimeError, "marker provenance"):
            unchanged_captions(before, report)

    def test_fractional_frames_and_duplicate_ids_are_rejected(self):
        report = self.report()
        report["captions"][0]["anchor"]["start"]["frame"] = 12.5
        with self.assertRaisesRegex(RuntimeError, "exact integers"):
            caption_snapshot(report)
        report = self.report()
        report["captions"].append(copy.deepcopy(report["captions"][0]))
        with self.assertRaisesRegex(RuntimeError, "unique"):
            caption_snapshot(report)


if __name__ == "__main__":
    unittest.main()
