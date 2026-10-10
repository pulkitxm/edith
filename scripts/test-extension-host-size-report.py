import hashlib
import importlib.util
import json
import plistlib
import shutil
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("host_size_report", Path(__file__).with_name("extension-host-size-report.py"))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)
normalize_executable = report.unsigned_executable_digest


class HostSizeReportTests(unittest.TestCase):
    def test_selected_scenarios_count_the_host_once_and_only_the_selected_packages(self):
        packages = [
            {"id": identifier, "installedBytes": 100, "downloadBytes": 40}
            for identifier in ["calendar", "clipboard", "systemStats", "usage", "unused"]
        ]
        measured = report.measure_scenarios({"installedBytes": 50}, packages)
        self.assertEqual(measured, [{"name": "Daily tools",
            "extensions": ["calendar", "clipboard", "systemStats", "usage"],
            "installedBytes": 450, "extensionDownloadBytes": 160}])
        self.assertEqual(report.measure_scenarios({"installedBytes": 50}, packages[:3]), [])

    def setUp(self):
        fixture = tempfile.TemporaryDirectory()
        self.addCleanup(fixture.cleanup)
        self.root = Path(fixture.name)
        self.app = self.root / "Fixture.app"
        self.executable = self.app / "Contents/MacOS/Edith"
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b"synthetic host fixture")
        self.packages = self.root / "packages"
        self.packages.mkdir()
        normalization = patch.object(report, "unsigned_executable_digest", side_effect=lambda path:
            hashlib.sha256(path.read_bytes().split(b"|signature:")[0]).hexdigest())
        normalization.start()
        self.addCleanup(normalization.stop)
        self.baseline = {
            "installedBytes": 1000, "zipBytes": 500, "sourceCommit": "baseline-fixture",
            "configuration": "Release", "architecture": "arm64", "signature": "ad-hoc",
            "xcode": "27.0 (fixture)", "sdk": "27.0",
        }

    def interim_report(self, *arguments, **keywords):
        return report.build_report(*arguments, **keywords, source_mode="interim")

    def package(self, identifier):
        archive = self.packages / f"{identifier}.zip"
        with zipfile.ZipFile(archive, "w") as zipped:
            zipped.writestr(f"{identifier}/payload", b"fixture")
        metadata = {
            "id": identifier, "version": "1.0.0", "downloadBytes": archive.stat().st_size,
            "installedBytes": 7, "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
            "sourceFingerprint": f"current-{identifier}",
        }
        (self.packages / f"{identifier}.json").write_text(json.dumps(metadata))

    def sealed_package(self, identifier, provenance=None, executable=None, contained_roles=None):
        self.package(identifier)
        path = self.packages / f"{identifier}.json"
        metadata = json.loads(path.read_text())
        metadata.update(hostABI="edith-host-2", architecture="arm64", dependencies=[])
        carrier = f"{identifier}/ExtensionCarrier.app"
        worker = f"{carrier}/Contents/Extensions/ExtensionWorker.appex"
        nested = f"{worker}/Contents/Resources/Payload/{identifier}"
        host_hash = report.digest_file(self.executable)
        info = {"CFBundleExecutable": "Edith", "EdithHostABI": "edith-host-2", "EdithExtensionID": identifier,
            "EdithExtensionVersion": metadata["version"], "EdithHostIdentifier": "com.example.fixture",
            "EdithExecutableProvenance": provenance or host_hash}
        entries = {f"{nested}/package.json": json.dumps({key: metadata[key]
            for key in ["id", "version", "hostABI", "architecture", "dependencies"]}).encode()}
        for number, bundle in enumerate([carrier, worker]):
            entries[f"{bundle}/Contents/Info.plist"] = plistlib.dumps(info)
            entries[f"{bundle}/Contents/MacOS/Edith"] = executable or self.executable.read_bytes() + f"|signature:{number}".encode()
        for role, bundle in (contained_roles or {}).items():
            entries[f"{bundle}/Contents/Info.plist"] = plistlib.dumps({**info, "EdithContainedRole": role,
                "EdithContainedExtensionID": identifier})
            entries[f"{bundle}/Contents/MacOS/Edith"] = self.executable.read_bytes() + f"|signature:{role}".encode()
        self.write_package_entries(identifier, entries, metadata)
        return entries

    def write_package_entries(self, identifier, entries, metadata=None):
        path = self.packages / f"{identifier}.json"
        metadata = metadata or json.loads(path.read_text())
        archive = path.with_suffix(".zip")
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zipped:
            for name, value in entries.items():
                zipped.writestr(name, value)
        metadata.update(downloadBytes=archive.stat().st_size, installedBytes=sum(map(len, entries.values())),
            sha256=report.digest_file(archive))
        path.write_text(json.dumps(metadata))

    def verify_host(self, identifier="sample", definition=None):
        return report.verify_package_host(self.packages, json.loads((self.packages / f"{identifier}.json").read_text()),
            definition or {"id": identifier}, self.app, "a" * 40, report.digest_file(self.executable),
            hashlib.sha256(self.executable.read_bytes()).hexdigest())

    def test_partial_coverage_lists_unmeasured_features_without_shipping_or_test_claims(self):
        self.package("sample")
        index = [{"id": "sample", "title": "Sample"}, {"id": "remaining", "title": "Remaining"}]
        result = self.interim_report(self.baseline, self.app, self.packages,
            [{"id": "sample", "contractVersion": 1}, {"id": "remaining"}], index)
        self.assertEqual(result["migratedExtensions"], 1)
        self.assertEqual(result["indexedExtensions"], 2)
        self.assertEqual(result["status"], "partial-package-coverage")
        self.assertEqual(result["unmeasuredExtensions"], ["remaining"])
        self.assertNotIn("appWithAllExtensions", result)
        self.assertEqual(result["appWithMigratedExtensions"]["installedBytes"], self.executable.stat().st_size + 7)
        rendered = report.render_markdown(result, index)
        self.assertIn("1 of the 2 indexed features", rendered)
        self.assertIn("Unmeasured features: Remaining.", rendered)
        self.assertIn("| Sample |", rendered)
        self.assertNotIn("| Remaining |", rendered)
        self.assertNotIn("All 1 migrated extensions pass", rendered)
        self.assertNotIn("not ready to merge", rendered)
        self.assertIn("It does not establish merge readiness", rendered)

    def test_complete_39_package_coverage_does_not_infer_publication_or_release_readiness(self):
        index = [{"id": f"sample{number}", "title": f"Sample {number}"} for number in range(39)]
        for entry in index:
            self.package(entry["id"])
        definitions = [{"id": entry["id"], "contractVersion": 1} for entry in index]
        fingerprints = {entry["id"]: f"current-{entry['id']}" for entry in index}
        result = self.interim_report(self.baseline, self.app, self.packages, definitions, index, fingerprints)
        self.assertEqual(result["status"], "all-indexed-packages-measured")
        self.assertEqual(result["unmeasuredExtensions"], [])
        self.assertEqual(result["measurement"]["artifactPublication"], "not-verified")
        self.assertTrue(result["measurement"]["sourceFingerprintsVerified"])
        rendered = report.render_markdown(result, index)
        self.assertIn("All 39 indexed features have measured", rendered)
        self.assertIn("All 39 measured packages", rendered)
        self.assertNotIn("remaining feature migrations", rendered)
        self.assertNotIn("remaining Home card data", rendered)
        self.assertIn("neither publishes them nor proves", rendered)
        self.assertIn("not shipping installer sizes", rendered)
        self.assertIn("size calculation does not verify code signatures", rendered)

    def test_build_provenance_uses_recorded_values_and_is_bound_to_the_executable(self):
        self.package("sample")
        index = [{"id": "sample", "title": "Sample"}]
        definitions = [{"id": "sample", "contractVersion": 1}]
        host_build = {
            "hostExecutableSHA256": hashlib.sha256(self.executable.read_bytes()).hexdigest(),
            "sourceCommit": "host-fixture", "configuration": "Release", "optimization": "-Osize",
            "linkTimeOptimization": "full",
            "architecture": "arm64", "signature": "ad-hoc", "xcode": "27.0 (fixture)", "sdk": "27.0",
        }
        result = self.interim_report(self.baseline, self.app, self.packages, definitions, index, host_build=host_build)
        self.assertEqual(result["measurement"]["hostBuild"]["signature"], "ad-hoc")
        self.assertEqual(result["measurement"]["hostBuild"]["linkTimeOptimization"], "full")
        self.assertNotIn("signature", result["measurement"])
        rendered = report.render_markdown(result, index)
        self.assertIn("Baseline build: source commit: `baseline-fixture`; configuration: `Release`", rendered)
        self.assertIn("Host build: source commit: `host-fixture`; configuration: `Release`; optimization: `-Osize`", rendered)
        self.assertIn("signing: `ad-hoc`", rendered)
        self.assertIn("link-time optimization: `full`", rendered)
        for dirty in [False, True]:
            host_build["sourceTreeDirty"] = dirty
            measured = self.interim_report(self.baseline, self.app, self.packages, definitions, index, host_build=host_build)
            self.assertEqual(measured["measurement"]["hostBuild"]["sourceTreeDirty"], dirty)
            self.assertIn(f"uncommitted source changes: `{dirty}`", report.render_markdown(measured, index))
        host_build["hostExecutableSHA256"] = "stale"
        with self.assertRaisesRegex(ValueError, "executable checksum"):
            self.interim_report(self.baseline, self.app, self.packages, definitions, index, host_build=host_build)

    def test_missing_host_build_metadata_never_assumes_its_configuration(self):
        self.package("sample")
        index = [{"id": "sample", "title": "Sample"}]
        result = self.interim_report(self.baseline, self.app, self.packages,
            [{"id": "sample", "contractVersion": 1}], index)
        self.assertEqual(result["measurement"]["hostBuild"], {})
        rendered = report.render_markdown(result, index)
        self.assertIn("Host build: Build configuration was not recorded.", rendered)
        self.assertIn("Current package source fingerprints were not checked", rendered)

    def test_component_totals_account_for_every_regular_file_without_counting_aliases(self):
        files = {
            "Contents/Frameworks/Sparkle.framework/Sparkle": b"updater",
            "Contents/Resources/index.json": b"[]",
            "Contents/Info.plist": b"metadata",
            "Contents/Library/LaunchDaemons/carrier.plist": b"carrier",
            "Contents/_CodeSignature/CodeResources": b"signature",
        }
        for relative, data in files.items():
            path = self.app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (self.executable.parent / "ed").symlink_to(self.executable)
        self.package("sample")
        index = [{"id": "sample", "title": "Sample"}]
        result = self.interim_report(self.baseline, self.app, self.packages,
            [{"id": "sample", "contractVersion": 1}], index)
        components = result["hostComponents"]
        self.assertEqual(components["hostAndCLI"], len(self.executable.read_bytes()))
        self.assertEqual(components["appUpdater"], len(b"updater"))
        self.assertEqual(components["resources"], len(b"[]"))
        self.assertEqual(components["bundleMetadata"], len(b"metadata") + len(b"carrier") + len(b"signature"))
        self.assertEqual(sum(components.values()), result["appWithoutExtensions"]["installedBytes"])
        rendered = report.render_markdown(result, index)
        self.assertIn("| Sparkle app updater | 7 |", rendered)
        self.assertIn(f"| Total empty host | {sum(components.values()):,} |", rendered)

    def test_platform_retirement_and_verification_are_separate_from_worker_exit(self):
        self.package("sample")
        index = [{"id": "sample", "title": "Sample"}]
        result = self.interim_report(self.baseline, self.app, self.packages,
            [{"id": "sample", "contractVersion": 1}], index)
        rendered = report.render_markdown(result, index)
        self.assertIn("meeting-microphone driver has separate retirement rules and can require a macOS restart", rendered)
        self.assertIn("independently installed OBS Virtual Camera provider", rendered)
        self.assertIn("Edith does not install, remove, or deactivate", rendered)
        self.assertNotIn("confirm camera-provider exit after macOS deactivation", rendered)
        self.assertIn("OS-managed deployment copies", rendered)
        self.assertIn("unregistered feature processes are outside", rendered)
        self.assertIn("does not prove that an OS-managed provider", rendered)
        self.assertIn("PR #1010", rendered)
        self.assertEqual(result["surfaceCustomization"]["verification"], "not-measured-by-size-report")

    def test_stale_or_missing_fingerprints_cannot_produce_size_claims(self):
        (self.packages / "sample.json").write_text(json.dumps({"id": "sample", "sourceFingerprint": "older-build"}))
        for fingerprints in [{}, {"sample": "current-build"}]:
            with self.assertRaisesRegex(ValueError, "Rebuild sample"):
                self.interim_report({}, Path("missing-app"), self.packages,
                    [{"id": "sample", "contractVersion": 1}], [{"id": "sample"}], fingerprints)

    def final_fixture(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.example.fixture"}))
        index = [{"id": f"sample{number}", "title": f"Sample {number}"} for number in range(39)]
        fingerprints = {}
        for entry in index:
            identifier = entry["id"]
            self.sealed_package(identifier)
            fingerprint = hashlib.sha256(identifier.encode()).hexdigest()
            path = self.packages / f"{identifier}.json"
            metadata = json.loads(path.read_text())
            metadata["sourceFingerprint"] = fingerprint
            path.write_text(json.dumps(metadata))
            fingerprints[identifier] = fingerprint
        commit = "a" * 40
        source = {"sourceCommit": commit, "sourceTreeDirty": False}
        host = {**source, "hostExecutableSHA256": hashlib.sha256(self.executable.read_bytes()).hexdigest()}
        return index, [{"id": entry["id"], "contractVersion": 1} for entry in index], fingerprints, source, host

    def test_final_requires_exact_clean_expected_source_without_rewriting_the_baseline(self):
        index, definitions, fingerprints, source, host = self.final_fixture()
        result = report.build_report(self.baseline, self.app, self.packages, definitions, index, fingerprints, host,
            expected_source_commit=source["sourceCommit"], source_state=source)
        self.assertEqual(result["measurement"]["sourceMode"], "final")
        self.assertEqual(result["measurement"]["baselineSourceCommit"], "baseline-fixture")
        self.assertEqual(result["measurement"]["expectedSourceCommit"], source["sourceCommit"])
        self.assertEqual(result["sourceFingerprints"], fingerprints)
        self.assertEqual({entry["id"]: entry["sourceFingerprint"] for entry in result["packages"]}, fingerprints)
        for expected, current, built in [
            (None, source, host), ("a" * 7, source, host),
            ("b" * 40, source, host), (source["sourceCommit"], {**source, "sourceTreeDirty": True}, host),
            (source["sourceCommit"], source, {**host, "sourceTreeDirty": True}),
            (source["sourceCommit"], source, {**host, "sourceCommit": "b" * 40}),
            (source["sourceCommit"], source, {key: value for key, value in host.items() if key != "sourceTreeDirty"}),
        ]:
            with self.subTest(expected=expected, current=current, built=built), self.assertRaisesRegex(ValueError, "source commit"):
                report.build_report(self.baseline, self.app, self.packages, definitions, index, fingerprints, built,
                    expected_source_commit=expected, source_state=current)

    def test_final_rejects_partial_coverage_extra_fingerprints_and_invalid_digests(self):
        index, definitions, fingerprints, source, host = self.final_fixture()
        for selected, values in [(definitions[:-1], fingerprints), (definitions, {**fingerprints, "foreign": "a" * 64}),
                                 (definitions, {**fingerprints, "sample0": "fixture"})]:
            with self.subTest(selected=selected, values=values), self.assertRaisesRegex(ValueError, "39 indexed|SHA-256"):
                report.build_report(self.baseline, self.app, self.packages, selected, index, values, host,
                    expected_source_commit=source["sourceCommit"], source_state=source)

    def test_swapped_metadata_id_cannot_borrow_another_packages_fingerprint(self):
        for identifier in ["first", "second"]:
            self.package(identifier)
        first = self.packages / "first.json"
        metadata = json.loads(first.read_text())
        metadata["id"] = "second"
        first.write_text(json.dumps(metadata))
        with self.assertRaisesRegex(ValueError, "identity differs from its filename"):
            self.interim_report(self.baseline, self.app, self.packages,
                [{"id": identifier, "contractVersion": 1} for identifier in ["first", "second"]],
                [{"id": identifier} for identifier in ["first", "second"]], {"first": "current-first", "second": "current-second"})

    def test_current_source_reader_includes_untracked_files_and_uses_owned_root(self):
        outputs = [type("Result", (), {"stdout": "a" * 40 + "\n"})(), type("Result", (), {"stdout": "?? pending-source.swift\n"})()]
        with patch.object(report.subprocess, "run", side_effect=outputs) as command:
            self.assertEqual(report.read_source_state(self.root), {"sourceCommit": "a" * 40, "sourceTreeDirty": True})
        self.assertEqual(command.call_args_list[1].args[0], ["git", "status", "--porcelain", "--untracked-files=normal"])
        self.assertEqual(command.call_args_list[1].kwargs["cwd"], self.root)

    def test_resigned_carriers_keep_actual_checksums_and_bytes_without_double_counting(self):
        index, definitions, fingerprints, source, host = self.final_fixture()
        result = report.build_report(self.baseline, self.app, self.packages, definitions, index, fingerprints, host,
            expected_source_commit=source["sourceCommit"], source_state=source)
        self.assertTrue(result["measurement"]["carrierHostProvenanceVerified"])
        provenance = result["packageHostProvenance"]["sample0"]
        self.assertEqual(provenance["sourceCommit"], source["sourceCommit"])
        self.assertEqual(provenance["sourceHostExecutableSHA256"], report.digest_file(self.executable))
        self.assertEqual(len(provenance["executables"]), 2)
        for executable in provenance["executables"]:
            self.assertNotEqual(executable["sha256"], report.digest_file(self.executable))
            self.assertGreater(executable["installedBytes"], self.executable.stat().st_size)
        self.assertEqual(result["appWithMigratedExtensions"]["installedBytes"],
            result["appWithoutExtensions"]["installedBytes"] + sum(entry["installedBytes"] for entry in result["packages"]))

    def test_sealed_provenance_cannot_disguise_foreign_executable_code(self):
        self.final_fixture()
        self.sealed_package("sample", executable=b"foreign code|signature:0")
        with self.assertRaisesRegex(ValueError, "executable code differs"):
            self.verify_host()
        self.sealed_package("sample", provenance="b" * 64)
        with self.assertRaisesRegex(ValueError, "provenance differs"):
            self.verify_host()

    def test_sealed_metadata_and_payload_must_match_exact_current_package(self):
        self.final_fixture()
        originals = self.sealed_package("sample")
        carrier = "sample/ExtensionCarrier.app/Contents/Info.plist"
        nested = "sample/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/sample/package.json"
        for key, value in [("EdithExtensionID", "foreign"), ("EdithExtensionVersion", "9.0.0"),
                           ("EdithHostABI", "edith-host-1"), ("EdithHostIdentifier", "com.foreign.host")]:
            entries = dict(originals)
            info = plistlib.loads(entries[carrier])
            info[key] = value
            entries[carrier] = plistlib.dumps(info)
            self.write_package_entries("sample", entries)
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "Sealed UI carrier|provenance differ"):
                self.verify_host()
        entries = dict(originals)
        manifest = json.loads(entries[nested])
        manifest["version"] = "9.0.0"
        entries[nested] = json.dumps(manifest).encode()
        self.write_package_entries("sample", entries)
        with self.assertRaisesRegex(ValueError, "Sealed payload manifest"):
            self.verify_host()
        del entries["sample/ExtensionCarrier.app/Contents/MacOS/Edith"]
        self.write_package_entries("sample", entries)
        entries[nested] = originals[nested]
        self.write_package_entries("sample", entries)
        with self.assertRaises(KeyError):
            self.verify_host()

    def test_unsafe_and_duplicate_archive_members_are_rejected(self):
        self.final_fixture()
        entries = self.sealed_package("sample")
        for name in ["sample/../foreign", "/sample/foreign", "sample\\foreign", "other/payload"]:
            self.write_package_entries("sample", {**entries, name: b"foreign"})
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "unsafe member"):
                self.verify_host()
        self.write_package_entries("sample", entries)
        with zipfile.ZipFile(self.packages / "sample.zip", "a") as zipped:
            with self.assertWarns(UserWarning):
                zipped.writestr(next(iter(entries)), b"duplicate")
        with self.assertRaisesRegex(ValueError, "duplicate members"):
            self.verify_host()

    def test_signature_removal_operates_only_on_private_copy_with_timeout(self):
        source = self.root / "signed-executable"
        source.write_bytes(b"code|signature:actual")
        def strip(arguments, **keywords):
            copied = Path(arguments[-1])
            self.assertNotEqual(copied, source)
            self.assertEqual(copied.read_bytes(), source.read_bytes())
            copied.write_bytes(b"code")
            self.assertEqual(keywords["timeout"], 30)
        with patch.object(report.subprocess, "run", side_effect=strip):
            actual = normalize_executable(source)
        self.assertEqual(actual, hashlib.sha256(b"code").hexdigest())
        self.assertEqual(source.read_bytes(), b"code|signature:actual")

    def camera_fixture(self):
        self.final_fixture()
        clone = self.root / "camera-source/Edith.app"
        shutil.copytree(self.app, clone)
        identifier = "com.pulkit.edith.tests.camera-build-00000000-0000-0000-0000-000000000001"
        info_path = clone / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleIdentifier"] = identifier
        info_path.write_bytes(plistlib.dumps(info))
        clone_executable = clone / "Contents/MacOS/Edith"
        clone_executable.write_bytes(self.executable.read_bytes() + b"|signature:clone")
        receipt = {"schema": 1, "sourceCommit": "a" * 40, "sourceHost": str(self.app.resolve()), "clone": str(clone),
            "identifier": identifier, "sourceExecutableSHA256": report.digest_file(self.executable),
            "executableBeforeSigningSHA256": report.digest_file(self.executable),
            "executableAfterSigningSHA256": report.digest_file(clone_executable),
            "unsignedExecutableSHA256": hashlib.sha256(self.executable.read_bytes()).hexdigest(),
            "sourceInventory": report.tree_inventory(self.app), "cloneInventory": report.tree_inventory(clone)}
        sidecar = self.packages / "virtualCamera.synthetic-host-provenance.json"
        sidecar.write_text(json.dumps(receipt))
        camera = "virtualCamera/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/virtualCamera/CameraCarrier.app"
        entries = self.sealed_package("virtualCamera", provenance=receipt["executableAfterSigningSHA256"],
            contained_roles={"cameraCarrier": camera})
        for name in entries:
            if name.endswith("Info.plist"):
                info = plistlib.loads(entries[name])
                info["EdithHostIdentifier"] = identifier
                entries[name] = plistlib.dumps(info)
        self.write_package_entries("virtualCamera", entries)
        role_receipt = {"schemaVersion": 1, "hostIdentifier": identifier, "version": "1.0.0", "hostABI": "edith-host-2",
            "roles": [{"role": "cameraCarrier", "executableBeforeSigningSHA256": receipt["executableAfterSigningSHA256"],
                "executableAfterSigningSHA256": hashlib.sha256(entries[f"{camera}/Contents/MacOS/Edith"]).hexdigest()}]}
        (self.packages / "virtualCamera.carrier-provenance.json").write_text(json.dumps(role_receipt))
        definition = {"id": "virtualCamera", "roles": ["cameraCarrier"], "systemExtensionCarrier": {"transport": "obs"}}
        return clone, receipt, role_receipt, definition

    def test_camera_clone_requires_exact_source_code_resources_and_role_binding(self):
        clone, receipt, roles, definition = self.camera_fixture()
        result = self.verify_host("virtualCamera", definition)
        self.assertEqual(result["syntheticHost"]["sourceCommit"], "a" * 40)
        self.assertEqual(len(result["executables"]), 3)
        self.assertNotEqual(result["syntheticHost"]["executableAfterSigningSHA256"], result["sourceHostExecutableSHA256"])
        path = self.packages / "virtualCamera.synthetic-host-provenance.json"
        for key, value in [("sourceCommit", "b" * 40), ("sourceExecutableSHA256", "b" * 64),
                           ("executableBeforeSigningSHA256", "b" * 64), ("unsignedExecutableSHA256", "b" * 64)]:
            path.write_text(json.dumps({**receipt, key: value}))
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "exact frozen host|frozen host code"):
                self.verify_host("virtualCamera", definition)
        path.write_text(json.dumps(receipt))
        role_path = self.packages / "virtualCamera.carrier-provenance.json"
        for changed in [{**roles, "hostIdentifier": "com.foreign"}, {**roles, "roles": []},
                        {**roles, "roles": [{**roles["roles"][0], "executableAfterSigningSHA256": "b" * 64}]}]:
            role_path.write_text(json.dumps(changed))
            with self.subTest(roles=changed), self.assertRaisesRegex(ValueError, "role.*provenance|role executable"):
                self.verify_host("virtualCamera", definition)
        role_path.write_text(json.dumps(roles))
        (clone / "Contents/Resources").mkdir()
        (clone / "Contents/Resources/foreign.txt").write_bytes(b"foreign")
        path.write_text(json.dumps({**receipt, "cloneInventory": report.tree_inventory(clone)}))
        with self.assertRaisesRegex(ValueError, "resources differ"):
            self.verify_host("virtualCamera", definition)

    def test_camera_clone_cannot_self_declare_changed_code_or_foreign_identity(self):
        clone, receipt, roles, definition = self.camera_fixture()
        path = self.packages / "virtualCamera.synthetic-host-provenance.json"
        info_path = clone / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleIdentifier"] = "com.foreign.host"
        info_path.write_bytes(plistlib.dumps(info))
        changed = {**receipt, "identifier": "com.foreign.host", "cloneInventory": report.tree_inventory(clone)}
        path.write_text(json.dumps(changed))
        with self.assertRaisesRegex(ValueError, "synthetic identity"):
            self.verify_host("virtualCamera", definition)
        info["CFBundleIdentifier"] = receipt["identifier"]
        info_path.write_bytes(plistlib.dumps(info))
        executable = clone / "Contents/MacOS/Edith"
        executable.write_bytes(b"foreign code|signature:clone")
        path.write_text(json.dumps({**receipt, "cloneInventory": report.tree_inventory(clone),
            "executableAfterSigningSHA256": report.digest_file(executable)}))
        with self.assertRaisesRegex(ValueError, "frozen host code"):
            self.verify_host("virtualCamera", definition)

    def test_ordinary_package_cannot_use_camera_clone_exception(self):
        self.final_fixture()
        self.sealed_package("sample")
        (self.packages / "sample.synthetic-host-provenance.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "only for Camera"):
            self.verify_host()

    def test_final_rejects_host_changed_during_package_provenance_measurement(self):
        index, definitions, fingerprints, source, host = self.final_fixture()
        verify = report.verify_package_host
        def inspect(*arguments):
            result = verify(*arguments)
            if arguments[1]["id"] == "sample38":
                self.executable.write_bytes(b"changed during measurement")
            return result
        with patch.object(report, "verify_package_host", side_effect=inspect), self.assertRaisesRegex(ValueError, "changed during"):
            report.build_report(self.baseline, self.app, self.packages, definitions, index, fingerprints, host,
                expected_source_commit=source["sourceCommit"], source_state=source)

    def test_unindexed_or_duplicate_extensions_cannot_inflate_coverage(self):
        definitions = [{"id": "sample", "contractVersion": 1}]
        for index in [[], [{"id": "other"}], [{"id": "sample"}, {"id": "sample"}]]:
            with self.assertRaisesRegex(ValueError, "host index"):
                self.interim_report({}, Path("missing"), Path("missing"), definitions, index)
        with self.assertRaisesRegex(ValueError, "host index"):
            self.interim_report({}, Path("missing"), Path("missing"), definitions * 2, [{"id": "sample"}])


if __name__ == "__main__":
    unittest.main()
