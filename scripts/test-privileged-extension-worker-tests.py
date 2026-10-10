import importlib.util
import json
import plistlib
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("privileged_wrapper", Path(__file__).with_name("test-privileged-extension-worker.py"))
wrapper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wrapper)


class PrivilegedWrapperTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.app = self.root / "Host.app"
        self.bundle(self.app, {"CFBundleIdentifier": "example.synthetic.host", "CFBundleExecutable": "Edith"})
        self.extracted = self.root / "extracted"
        self.extracted.mkdir()
        for relative in (wrapper.CARRIER, wrapper.WORKER):
            self.bundle(self.extracted.joinpath(*relative.parts), {"CFBundleExecutable": "Edith", "EdithExtensionID": "lidAwake", "EdithHostABI": "edith-host-2"})
        self.role = self.extracted.joinpath(*wrapper.ROLE.parts)
        self.bundle(self.role, {"CFBundleIdentifier": "com.pulkit.edith.extensions.lidAwake.privileged", "CFBundleExecutable": "Runtime", "EdithHostABI": "edith-host-2"})

    def bundle(self, path, info):
        binary = path / "Contents/MacOS" / info["CFBundleExecutable"]
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_bytes(b"synthetic code")
        with (path / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump(info, stream)

    def lifetime(self):
        return {"signedWorkerCases": 6, "confirmedQuitExited": True, "forcedStopRestoredCallback": True,
            "eofRestoredCallback": True, "staleWorkerRejected": True, "forcedReasonRetentionRejected": True,
            "parentExitWithOpenInputRestoredCallback": True, "operatingSystemActions": 0, "visibleWindows": 0}

    def test_payload_checks_all_signatures_and_same_code_without_executing_role(self):
        with patch.object(wrapper, "signed") as signed, patch.object(wrapper, "unsigned_digest", return_value="same") as digest, patch.object(wrapper, "checked") as execute:
            self.assertEqual(wrapper.verify_payload(self.app, self.extracted), "same")
            self.assertEqual(signed.call_count, 4)
            self.assertEqual(digest.call_count, 3)
            execute.assert_not_called()
            self.assertNotIn(self.role / "Contents/MacOS/Runtime", [call.args[0] for call in digest.call_args_list])

    def test_mismatched_code_and_wrong_role_metadata_fail_closed(self):
        with patch.object(wrapper, "signed"), patch.object(wrapper, "unsigned_digest", side_effect=["original", "different"]):
            with self.assertRaises(ValueError):
                wrapper.verify_payload(self.app, self.extracted)
        self.bundle(self.role, {"CFBundleIdentifier": "com.pulkit.edith.tests.lifetime-runtime", "CFBundleExecutable": "Runtime", "EdithHostABI": "edith-host-2"})
        with patch.object(wrapper, "signed"), patch.object(wrapper, "unsigned_digest", return_value="same"):
            with self.assertRaises(ValueError):
                wrapper.verify_payload(self.app, self.extracted)

    def test_archive_rejects_traversal_symlinks_normalized_duplicates_and_foreign_roots(self):
        cases = [("lidAwake/../escape", None), ("foreign/file", None), ("/lidAwake/file", None), ("lidAwake/link", stat.S_IFLNK | 0o777)]
        for name, mode in cases:
            archive = self.root / "unsafe.zip"
            with zipfile.ZipFile(archive, "w") as package:
                entry = zipfile.ZipInfo(name)
                if mode is not None:
                    entry.external_attr = mode << 16
                package.writestr(entry, b"synthetic")
            with self.subTest(name=name), self.assertRaises(ValueError):
                wrapper.extract_package(archive, self.root / "rejected")
        with zipfile.ZipFile(archive, "w") as package:
            package.writestr("lidAwake/path/file", b"first")
            package.writestr("lidAwake/path//file", b"second")
        with self.assertRaises(ValueError):
            wrapper.extract_package(archive, self.root / "rejected")
        self.assertFalse((self.root / "rejected").exists())

    def test_valid_archive_extracts_nested_role_and_rejects_flat_payload(self):
        archive = self.root / "valid.zip"
        with zipfile.ZipFile(archive, "w") as package:
            package.writestr(str(wrapper.ROLE / "Contents/Info.plist"), b"synthetic")
        destination = self.root / "valid"
        wrapper.extract_package(archive, destination)
        self.assertTrue(destination.joinpath(*wrapper.ROLE.parts, "Contents/Info.plist").is_file())
        with zipfile.ZipFile(archive, "w") as package:
            package.writestr("lidAwake/privileged.bundle/Contents/Info.plist", b"synthetic")
        with self.assertRaises(ValueError):
            wrapper.extract_package(archive, self.root / "flat")

    def test_preparation_compiles_only_tracked_callback_and_does_not_launch_host(self):
        with patch.object(wrapper, "checked") as execute, patch.object(wrapper, "unsigned_digest", return_value="same"):
            cloned, callback = wrapper.prepare_synthetic(self.app, self.root / "synthetic", "same")
        self.assertTrue(wrapper.info(cloned)["CFBundleIdentifier"].startswith("com.pulkit.edith.dev.lifetime-"))
        self.assertEqual(wrapper.info(callback)["CFBundleIdentifier"], "com.pulkit.edith.tests.lifetime-runtime")
        commands = [call.args[0] for call in execute.call_args_list]
        compilers = [command for command in commands if command[0] == "xcrun"]
        self.assertEqual(len(compilers), 1)
        self.assertIn(str(wrapper.FIXTURES / "privileged-lifecycle-runtime.swift"), compilers[0])
        self.assertTrue(all(command[0] in ("codesign", "xcrun") for command in commands))
        self.assertNotIn(str(self.role), compilers[0])

    def test_runner_executes_only_synthetic_pair_and_maps_actual_proof(self):
        cloned = self.root / "Synthetic.app"
        callback = self.root / "Synthetic.bundle"
        response = subprocess.CompletedProcess([], 0, json.dumps(self.lifetime()).encode(), b"")
        with patch.object(wrapper.os, "geteuid", return_value=501), patch.object(wrapper, "extract_package"), patch.object(wrapper, "verify_payload", return_value="same"), patch.object(wrapper, "prepare_synthetic", return_value=(cloned, callback)), patch.object(wrapper, "checked", return_value=response) as execute:
            result = wrapper.run(self.app, self.root / "package.zip")
        command = execute.call_args.args[0]
        self.assertEqual(command[-4:], ["--app", str(cloned), "--bundle", str(callback)])
        self.assertNotIn(str(self.role), command)
        self.assertTrue(result["restoredBeforeExit"])
        self.assertTrue(result["connectionLossExited"])
        self.assertFalse(result["shippingPrivilegedRoleExecuted"])
        self.assertEqual(result["productionSystemEffects"], 0)
        self.assertEqual(result["disabledProcesses"], 0)

    def test_failed_shipping_admission_never_prepares_or_runs_callback(self):
        with patch.object(wrapper.os, "geteuid", return_value=501), patch.object(wrapper, "extract_package"), patch.object(wrapper, "verify_payload", side_effect=ValueError("Bad signature")), patch.object(wrapper, "prepare_synthetic") as prepare, patch.object(wrapper, "checked") as execute:
            with self.assertRaises(ValueError):
                wrapper.run(self.app, self.root / "package.zip")
            prepare.assert_not_called()
            execute.assert_not_called()
        for key in ("signedWorkerCases", "operatingSystemActions", "visibleWindows"):
            value = self.lifetime()
            value[key] = float(value[key])
            with self.subTest(key=key), self.assertRaises(ValueError):
                wrapper.result_from_lifetime(value)

    def test_failed_proofs_and_noncanonical_hosts_do_not_launch_lifecycle(self):
        for key in ("forcedStopRestoredCallback", "eofRestoredCallback", "staleWorkerRejected", "parentExitWithOpenInputRestoredCallback"):
            value = self.lifetime()
            value[key] = False
            with self.subTest(key=key), self.assertRaises(ValueError):
                wrapper.result_from_lifetime(value)
        for key in ("operatingSystemActions", "visibleWindows"):
            value = self.lifetime()
            value[key] = 1
            with self.assertRaises(ValueError):
                wrapper.result_from_lifetime(value)
        link = self.root / "Linked.app"
        link.symlink_to(self.app, target_is_directory=True)
        with patch.object(wrapper.os, "geteuid", return_value=501), patch.object(wrapper, "checked") as execute:
            with self.assertRaises(ValueError):
                wrapper.run(link, self.root / "package.zip")
            execute.assert_not_called()


if __name__ == "__main__":
    unittest.main()
