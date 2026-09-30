import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

from editor_parity_cli import REQUIRED_GROUPS, publish_result


class PublicationTests(unittest.TestCase):
    def setUp(self):
        parent = pathlib.Path(os.environ.get("TMPDIR", tempfile.gettempdir())) / "opencode"
        parent.mkdir(exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(prefix="parity-publication-controls-", dir=parent)
        self.root = pathlib.Path(self.directory.name)
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.groups = {name: {"control": True} for name in REQUIRED_GROUPS}
        self.addCleanup(self.directory.cleanup)

    def test_missing_group_never_creates_any_result_file(self):
        self.groups.pop("masteredAudio")
        with self.assertRaisesRegex(AssertionError, "Every required"):
            publish_result(self.workspace, self.groups, "full")
        self.assertEqual(list(self.workspace.iterdir()), [])

    def test_legacy_dangling_temporary_symlink_is_never_followed_or_removed(self):
        external = self.root / "must-not-be-created"
        legacy = self.workspace / ".result.json.tmp"
        legacy.symlink_to(external)
        publish_result(self.workspace, self.groups, "quick")
        self.assertTrue(legacy.is_symlink())
        self.assertFalse(external.exists())
        self.assertFalse(json.loads((self.workspace / "quick-result.json").read_text())["fullDeliveryAcceptance"])
        self.assertEqual(set(self.workspace.iterdir()), {legacy, self.workspace / "quick-result.json"})

    def test_existing_result_bytes_are_preserved(self):
        result = self.workspace / "result.json"
        original = b"existing result bytes\n"
        result.write_bytes(original)
        with self.assertRaisesRegex(AssertionError, "must not already exist"):
            publish_result(self.workspace, self.groups, "full")
        self.assertEqual(result.read_bytes(), original)
        self.assertEqual(list(self.workspace.iterdir()), [result])

    def test_dangling_result_symlink_is_preserved_without_external_writes(self):
        external = self.root / "must-not-be-created"
        result = self.workspace / "result.json"
        result.symlink_to(external)
        with self.assertRaisesRegex(AssertionError, "must not already exist"):
            publish_result(self.workspace, self.groups, "full")
        self.assertTrue(result.is_symlink())
        self.assertFalse(external.exists())
        self.assertEqual(list(self.workspace.iterdir()), [result])

    def test_existing_result_symlink_target_is_preserved(self):
        external = self.root / "existing-external"
        external.write_bytes(b"external bytes\n")
        result = self.workspace / "result.json"
        result.symlink_to(external)
        with self.assertRaisesRegex(AssertionError, "must not already exist"):
            publish_result(self.workspace, self.groups, "full")
        self.assertTrue(result.is_symlink())
        self.assertEqual(external.read_bytes(), b"external bytes\n")

    def test_concurrent_result_creation_wins_without_clobber(self):
        link = os.link
        result = self.workspace / "result.json"

        def create_before_link(source, destination, **options):
            self.assertTrue(pathlib.Path(source).is_file())
            self.assertFalse(pathlib.Path(source).is_symlink())
            json.loads(pathlib.Path(source).read_text())
            result.write_bytes(b"concurrent winner\n")
            link(source, destination, **options)

        with mock.patch("editor_parity_cli.os.link", side_effect=create_before_link):
            with self.assertRaisesRegex(AssertionError, "must not already exist"):
                publish_result(self.workspace, self.groups, "full")
        self.assertEqual(result.read_bytes(), b"concurrent winner\n")
        self.assertEqual(list(self.workspace.iterdir()), [result])


if __name__ == "__main__":
    unittest.main()
