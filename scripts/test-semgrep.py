import importlib.util
import pathlib
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("semgrep_check", pathlib.Path(__file__).with_name("check-semgrep.py"))
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class SemgrepReviewTests(unittest.TestCase):
    def report(self, path=CHECK.MUSIC_PATH, rule=CHECK.MUSIC_UNSAFE_RULE):
        return {"results": [{"path": path, "check_id": rule}], "errors": []}

    def test_exact_reviewed_source_is_allowed(self):
        self.assertEqual(CHECK.blocking_findings(self.report(), 1, CHECK.MUSIC_REVIEWED_SHA256), ([], 1))

    def test_changed_source_requires_another_review(self):
        report = self.report()
        self.assertEqual(CHECK.blocking_findings(report, 1, "changed"), (report["results"], 0))

    def test_other_music_rules_remain_blocking(self):
        report = self.report(rule="rust.lang.security.other")
        self.assertEqual(CHECK.blocking_findings(report, 1, CHECK.MUSIC_REVIEWED_SHA256), (report["results"], 0))

    def test_unsafe_in_other_sources_remains_blocking(self):
        report = self.report(path="Extensions/other/Native/src/lib.rs")
        self.assertEqual(CHECK.blocking_findings(report, 1, CHECK.MUSIC_REVIEWED_SHA256), (report["results"], 0))

    def test_scan_errors_are_not_filtered(self):
        report = self.report()
        report["errors"] = [{"message": "incomplete scan"}]
        with self.assertRaises(ValueError):
            CHECK.blocking_findings(report, 1, CHECK.MUSIC_REVIEWED_SHA256)

    def test_existing_nonfatal_parser_warnings_do_not_hide_findings(self):
        report = self.report(rule="rust.lang.security.other")
        report["errors"] = [{"level": "warn", "code": 3, "path": "Extensions/other/File.swift"}]
        self.assertEqual(CHECK.blocking_findings(report, 1, CHECK.MUSIC_REVIEWED_SHA256), (report["results"], 0))

    def test_reviewed_source_parser_warnings_are_blocking(self):
        report = self.report()
        report["errors"] = [{"level": "warn", "code": 3, "path": CHECK.MUSIC_PATH}]
        with self.assertRaises(ValueError):
            CHECK.blocking_findings(report, 1, CHECK.MUSIC_REVIEWED_SHA256)

    def test_failed_engine_is_not_filtered(self):
        with self.assertRaises(ValueError):
            CHECK.blocking_findings(self.report(), 2, CHECK.MUSIC_REVIEWED_SHA256)

    def test_malformed_reports_fail_closed(self):
        for report in (None, {}, {"results": [], "errors": None}, {"results": [None], "errors": []}):
            with self.assertRaises(ValueError):
                CHECK.blocking_findings(report, 0, CHECK.MUSIC_REVIEWED_SHA256)
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "report.json"
            path.write_text("invalid")
            with self.assertRaises(ValueError):
                CHECK.read_report(path)

    def test_oversized_report_is_rejected_before_loading(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "report.json"
            with path.open("wb") as output:
                output.truncate(CHECK.MAXIMUM_REPORT_BYTES + 1)
            with self.assertRaises(ValueError):
                CHECK.read_report(path)


if __name__ == "__main__":
    unittest.main()
