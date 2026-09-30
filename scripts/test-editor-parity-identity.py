import os
import pathlib
import plistlib
import subprocess
import tempfile
import unittest

from editor_parity_identity import runtime_artifacts, runtime_identity, verify_runtime


class RuntimeIdentityTests(unittest.TestCase):
    def setUp(self):
        parent = pathlib.Path(os.environ.get("TMPDIR", tempfile.gettempdir())) / "opencode"
        parent.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="parity-identity-", dir=parent)
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        contents = self.root / "Synthetic.app/Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        self.ed = contents / "MacOS/ed"
        self.ed.symlink_to("../Resources/ed-launcher")
        self.launcher = contents / "Resources/ed-launcher"
        self.launcher.write_bytes((pathlib.Path(__file__).resolve().parent.parent / "Resources/ed-launcher").read_bytes())
        self.runtime = contents / "MacOS/Edith"
        self.runtime.write_bytes(b"synthetic runtime version one")
        self.info = contents / "Info.plist"
        self.info.write_bytes(plistlib.dumps({"CFBundleExecutable": "Edith", "CFBundleIdentifier": "com.pulkit.edith.dev.synthetic"}))

    def test_unchanged_packaged_symlink_preserves_runtime_identity(self):
        identity = runtime_identity(self.ed)
        verify_runtime(identity, "unchanged")
        self.assertEqual(pathlib.Path(identity["entrypointPath"]), self.ed)
        self.assertEqual(set(runtime_artifacts(identity)), {self.launcher.resolve(), self.runtime.resolve(), self.info.resolve()})

    def test_runtime_swap_with_unchanged_launcher_invalidates_quick_identity(self):
        identity = runtime_identity(self.ed)
        launcher = self.launcher.read_bytes()
        self.runtime.write_bytes(b"synthetic runtime version two")
        self.assertEqual(self.launcher.read_bytes(), launcher)
        self.assertNotEqual(runtime_identity(self.ed), identity)
        with self.assertRaisesRegex(AssertionError, "runtime identity changed"):
            verify_runtime(identity, "before full publication")

    def test_development_slot_change_is_rejected(self):
        identity = runtime_identity(self.ed)
        metadata = plistlib.loads(self.info.read_bytes())
        metadata["CFBundleIdentifier"] = "com.pulkit.edith.dev.other"
        self.info.write_bytes(plistlib.dumps(metadata))
        with self.assertRaisesRegex(AssertionError, "runtime identity changed"):
            verify_runtime(identity, "after lifecycle")

    def test_standalone_runtime_mutation_is_rejected(self):
        ed = self.root / "ed"
        ed.write_bytes(b"synthetic standalone executable")
        identity = runtime_identity(ed)
        verify_runtime(identity, "unchanged raw CLI")
        self.assertFalse(identity["packaged"])
        ed.write_bytes(b"changed standalone executable")
        with self.assertRaisesRegex(AssertionError, "runtime identity changed"):
            verify_runtime(identity, "after render")

    def test_arbitrary_packaged_shell_is_not_inferred(self):
        self.ed.unlink()
        self.ed.write_bytes(b"synthetic arbitrary shell")
        with self.assertRaisesRegex(AssertionError, "standard MacOS/ed"):
            runtime_identity(self.ed)

    def test_changed_launcher_is_rejected_without_execution(self):
        self.launcher.write_bytes(b"synthetic arbitrary delegation")
        with self.assertRaisesRegex(AssertionError, "fixed delegation contract"):
            runtime_identity(self.ed)

    def test_standard_wrapper_executes_the_protected_runtime(self):
        self.runtime.write_bytes(b'#!/bin/sh\n[ "$EDITH_CLI" = 1 ] || exit 2\nprintf "synthetic-runtime:%s" "$1"\n')
        self.runtime.chmod(0o755)
        self.launcher.chmod(0o755)
        identity = runtime_identity(self.ed)
        result = subprocess.run([str(self.ed), "identity-probe"], capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout, "synthetic-runtime:identity-probe")
        verify_runtime(identity, "after actual wrapper execution")


if __name__ == "__main__":
    unittest.main()
