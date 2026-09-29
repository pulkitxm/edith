import copy
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from fractions import Fraction
from unittest import mock

from editor_acceptance_captions import caption_snapshot, unchanged_captions
from editor_acceptance_delivery import checked_progress
from editor_acceptance_markers import mapped_frames, marker_snapshot
from editor_acceptance_media import envelope, unique_usage
from editor_acceptance_publications import protected_snapshot, publication_reordered


class OrchestrationContractTests(unittest.TestCase):
    def check_existing_workspace_preserved(self, symlink):
        root = pathlib.Path(os.environ.get("TMPDIR", tempfile.gettempdir())) / "opencode"
        root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="acceptance-existing-", dir=root) as directory:
            target = pathlib.Path(directory) / "unrelated"
            target.mkdir()
            result = target / "result.json"
            original = b'{"unrelated":"existing result"}\n'
            result.write_bytes(original)
            workspace = target
            if symlink:
                workspace = pathlib.Path(directory) / "workspace-link"
                workspace.symlink_to(target, target_is_directory=True)
            process = subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name("test-editor-acceptance.py")),
                                      "--workspace", str(workspace), "--fixture-only"], capture_output=True, text=True, timeout=30)
            self.assertEqual(process.returncode, 1)
            self.assertIn("Workspace must not already exist", process.stderr)
            self.assertEqual(result.read_bytes(), original)
            self.assertEqual(list(target.iterdir()), [result])
            if symlink:
                self.assertTrue(workspace.is_symlink())

    def test_existing_unrelated_workspace_is_preserved(self):
        self.check_existing_workspace_preserved(False)

    def test_existing_symlink_workspace_is_preserved(self):
        self.check_existing_workspace_preserved(True)

    def test_final_success_requires_every_requested_check(self):
        spec = importlib.util.spec_from_file_location("acceptance_runner", pathlib.Path(__file__).with_name("test-editor-acceptance.py"))
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        root = pathlib.Path(os.environ.get("TMPDIR", tempfile.gettempdir())) / "opencode"
        root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="acceptance-orchestration-", dir=root) as directory:
            fixture = pathlib.Path(directory) / "fixture"
            fixture.mkdir()
            (fixture / "manifest.json").write_text('{"shots":[]}')
            core_calls = []

            def process(arguments, **kwargs):
                if arguments[1] == "inspect":
                    core_calls.append(arguments)
                    value = {"checksPassed": True, "sha256": "synthetic"}
                elif arguments[1] == "verify-fixture":
                    value = {"fixtureVerified": True}
                elif arguments[3] == "schema":
                    value = {"properties": {"operations": {"items": {"oneOf": [
                        {"properties": {name: {}}} for name in ("canvas", "addAudio", "videoSettings")
                    ]}}}}
                elif arguments[3] == "show":
                    value = {"audioTracks": [{"timebase": "output"}]}
                else:
                    value = {"written": "--dry-run" not in arguments, "aliases": {str(i): str(i) for i in range(45)}, "frame": 15, "time": 0.25}
                progress = '{"version":1,"event":"progress","percent":100}' if "--progress" in arguments else ""
                return subprocess.CompletedProcess(arguments, 0, json.dumps(value), progress)

            for failing in (True, False):
                workspace = pathlib.Path(directory) / str(failing)
                arguments = ["acceptance", "--workspace", str(workspace), "--fixture", str(fixture),
                             "--ed", sys.executable, "--media-helper", "synthetic-helper", "--delivery-checks"]
                delivery = mock.Mock(side_effect=RuntimeError("Synthetic delivery failed") if failing else None, return_value={})
                with mock.patch.object(sys, "argv", arguments), mock.patch.object(runner.subprocess, "run", side_effect=process), \
                        mock.patch.multiple(runner, check_sources=mock.Mock(), check_project=mock.Mock(), checked_report=mock.Mock(),
                                            digest=mock.Mock(return_value="synthetic"), exercise_delivery=delivery,
                                            exercise_variable_speed=mock.Mock(return_value={})), \
                        contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    code = runner.cli()
                    delivery.assert_called_once()
                    self.assertEqual(code, 1 if failing else 0)
                    result = workspace / "result.json"
                    self.assertEqual(result.exists(), not failing)
                    self.assertFalse((workspace / ".result.json.tmp").exists())
                    if not failing:
                        self.assertEqual(json.loads(result.read_text())["pendingGroups"], ["markers", "captions", "media", "publications"])
                        original = result.read_bytes()
                        self.assertEqual(runner.cli(), 1)
                        self.assertEqual(result.read_bytes(), original)
            self.assertEqual(len(core_calls), 2)
            failed = subprocess.CompletedProcess(["synthetic-helper"], 1, "not JSON", "Synthetic inspector failed")
            with mock.patch.object(runner.subprocess, "run", return_value=failed):
                with self.assertRaisesRegex(RuntimeError, "Synthetic inspector failed"):
                    runner.run(["synthetic-helper", "inspect"])


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


class MediaContractTests(unittest.TestCase):
    def test_known_reuse_cannot_pass_unique_original_acceptance(self):
        report = {"projectCount": 1, "occurrenceCount": 45, "uniqueClipCount": 45,
                  "uniqueByteIdentityCount": 45, "uniqueOriginalCount": 45,
                  "conflictCount": 0, "assessment": "noKnownReuse"}
        unique_usage(report, 1, 45)
        report.update(uniqueOriginalCount=44, conflictCount=1, assessment="knownReuseDetected")
        with self.assertRaisesRegex(RuntimeError, "known source reuse"):
            unique_usage(report, 1, 45)

    def test_read_only_media_envelope_cannot_report_a_write(self):
        value = {"version": 1, "operation": "usage", "written": False, "result": {"projectCount": 6}}
        self.assertEqual(envelope(value, "usage"), {"projectCount": 6})
        value["written"] = True
        with self.assertRaisesRegex(RuntimeError, "envelope mismatch"):
            envelope(value, "usage")


class MarkerContractTests(unittest.TestCase):
    def test_mapping_is_half_open_and_rounds_on_exact_rational_grid(self):
        actual = mapped_frames([47999, 48000, 72000, 95999, 96000], 48000,
                               Fraction(1), Fraction(2), Fraction(3), Fraction(2), Fraction(60000, 1001))
        self.assertEqual(actual, [180, 195, 210])

    def test_marker_output_seconds_must_match_exact_anchor(self):
        report = {"version": 1, "positionUnit": "output_frames", "markers": [{
            "id": "synthetic-beat", "frame": 60, "frameRate": {"numerator": 60000, "denominator": 1001},
            "label": "Synthetic beat", "kind": "manual", "outputSeconds": 1.001,
        }]}
        self.assertEqual(marker_snapshot(report)["synthetic-beat"][:3], (60, 60000, 1001))
        report["markers"][0]["outputSeconds"] = 1
        with self.assertRaisesRegex(RuntimeError, "rational position"):
            marker_snapshot(report)


class DeliveryContractTests(unittest.TestCase):
    def progress(self, values):
        return "\n".join(json.dumps({"version": 1, "event": "progress", "percent": value}) for value in values)

    def test_bounded_completed_progress(self):
        self.assertEqual(checked_progress(self.progress([0, 12, 99, 100])), 4)
        self.assertEqual(checked_progress(self.progress(range(101))), 101)

    def test_repeated_reversed_or_unfinished_progress_is_rejected(self):
        for values in ([0, 20, 20, 100], [0, 50, 25, 100], [0, 99]):
            with self.assertRaisesRegex(RuntimeError, "increase strictly"):
                checked_progress(self.progress(values))
        with self.assertRaisesRegex(RuntimeError, "1 through 101"):
            checked_progress(self.progress(range(102)))
        with self.assertRaisesRegex(RuntimeError, "Invalid delivery progress"):
            checked_progress(self.progress([-1, 100]))


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
