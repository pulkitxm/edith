import copy
import os
import pathlib
import tempfile
import unittest

from editor_acceptance_captions import caption_snapshot, unchanged_captions
from editor_acceptance_publications import protected_snapshot, publication_reordered


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


class PublicationContractTests(unittest.TestCase):
    def manifest(self):
        return {"version": 1, "items": [
            {"projectID": f"project-{index}", "projectPath": f"/synthetic/cut-{index}.openscreen", "title": f"Synthetic {index}"}
            for index in range(6)
        ]}

    def test_first_to_second_preserves_complete_entries(self):
        before = self.manifest()
        order = ["project-1", "project-0", "project-2", "project-3", "project-4", "project-5"]
        after = {"version": 1, "items": [before["items"][index] for index in (1, 0, 2, 3, 4, 5)]}
        publication_reordered(before, after, order)
        changed = copy.deepcopy(after)
        changed["items"][1]["title"] = "Unexpected retitle"
        with self.assertRaisesRegex(RuntimeError, "identity, path, or title"):
            publication_reordered(before, changed, order)

    def test_missing_or_repeated_projects_are_rejected(self):
        before = self.manifest()
        with self.assertRaisesRegex(RuntimeError, "every project exactly once"):
            publication_reordered(before, before, ["project-0"] * 6)
        with self.assertRaisesRegex(RuntimeError, "every project exactly once"):
            publication_reordered(before, before, [f"project-{index}" for index in range(5)])

    def test_ledger_receipt_changes_are_detected(self):
        root = pathlib.Path(os.environ.get("TMPDIR", tempfile.gettempdir())) / "opencode"
        root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="publication-contract-", dir=root) as directory:
            receipt = pathlib.Path(directory) / "synthetic-receipt.json"
            receipt.write_text('{"source":"synthetic-001"}')
            before = protected_snapshot([directory])
            self.assertEqual(before, protected_snapshot([directory]))
            receipt.write_text('{"source":"synthetic-002"}')
            self.assertNotEqual(before, protected_snapshot([directory]))
            receipt.unlink()
            self.assertNotEqual(before, protected_snapshot([directory]))


if __name__ == "__main__":
    unittest.main()
