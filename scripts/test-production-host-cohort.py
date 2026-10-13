import copy
import importlib.util
import json
import pathlib
import unittest


SPEC = importlib.util.spec_from_file_location("cohort", pathlib.Path(__file__).parent / "hosted-public-release/production-cohort.py")
COHORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COHORT)


def synthetic_request():
    requirement = 'identifier "com.pulkit.edith" and anchor apple generic and certificate leaf[subject.OU] = "ABCDEFGHIJ"'
    hosts = {}
    packages = {}
    catalogs = {}
    for index, generation in enumerate(["previous", "current"], 1):
        sha = str(index) * 64
        version = f"0.0.{400 + index}"
        hosts[generation] = {"source": str(index) * 40, "run": index, "tag": "v" + version, "version": version, "build": index, "proofSHA256": sha, "dmgURL": f"https://github.com/pulkitxm/edith/releases/download/v{version}/Edith.dmg", "dmgSHA256": sha, "dmgBytes": 100, "appcastSHA256": sha, "hostExecutableSHA256": sha, "normalizedUnsignedSHA256": sha, "normalization": "arm64-terminal-linkedit-vmsize-after-verified-signature-removal-v1", "installedBytes": 200, "extensionPayloadBytes": 0, "hostABI": "edith-host-2", "architecture": "arm64", "teamIdentifier": "ABCDEFGHIJ", "certificateCategory": "Apple Development", "designatedRequirement": requirement, "deepStrictSignatureVerified": True, "sparkleEd25519Verified": True, "notarization": "skipped", "publicationVerified": True}
        packages[generation] = {"id": "keepAwake", "source": str(index + 2) * 40, "run": index + 2, "version": f"1.0.{index - 1}", "archiveURL": f"https://github.com/pulkitxm/edith/releases/download/extensions%2FkeepAwake%2F1.0.{index - 1}-{str(index + 2) * 20}/keepAwake.zip", "archiveSHA256": str(index + 2) * 64, "downloadBytes": 300, "installedBytes": 600, "sourceFingerprint": str(index + 2) * 64, "hostABI": "edith-host-2", "architecture": "arm64", "minimumSystemVersion": "14.0.0", "dependencies": [], "workerContract": {"schema": 2, "carrierInputSHA256": sha, "frozenHostSHA256": sha, "packagedHostRequirement": requirement, "helperExecutable": "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/keepAwake/helper.bundle/Contents/MacOS/Runtime", "uiExecutable": "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/MacOS/Edith", "helperSHA256": sha, "uiSHA256": sha, "carrierSHA256": sha, "signatureVerified": True}}
        catalogs[generation] = {"revision": index, "sha256": sha, "bytes": 100, "signatureVerified": True, "selectedVersion": packages[generation]["version"], "selectedArchiveSHA256": packages[generation]["archiveSHA256"]}
    return {"schema": 1, "source": "a" * 40, "application": COHORT.APPLICATION, "hosts": hosts, "packages": packages, "catalogs": catalogs}


def environment():
    return {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS", "GITHUB_REPOSITORY": "pulkitxm/edith", "GITHUB_REPOSITORY_ID": "1289153439", "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": "a" * 40, "GITHUB_ACTOR_ID": "65671483", "PUBLIC_RELEASE_VERIFICATION": "1", "PUBLISH": "false", "REBUILD": ""}


def observation(value):
    home = "/Users/synthetic"
    return {"application": COHORT.APPLICATION, "accountHome": home, "effectiveUID": 501, "realUID": 501, "canonicalHome": home, "absentPaths": [COHORT.APPLICATION] + [home + suffix for suffix in ["/Library/Application Support/Edith", "/Library/Caches/Edith", "/Library/Logs/Edith", "/Library/Preferences/com.pulkit.edith.plist", "/Library/Preferences/com.pulkit.edith.host.plist", "/Library/Preferences/com.pulkit.edith.shared.plist"]], "existingProductionProcesses": 0, "inputsVerified": True, "initialCatalog": value["catalogs"]["previous"]}


class ProductionCohortContracts(unittest.TestCase):
    def test_supported_trust_classes_record_actual_notarization_without_claiming_execution(self):
        for trust, notarization in [("Apple Development", "skipped"), ("Developer ID Application", "verified"), ("Apple Distribution", "skipped")]:
            value = synthetic_request()
            for host in value["hosts"].values():
                host["certificateCategory"] = trust
                host["notarization"] = notarization
            result = COHORT.admit_plan(value, environment(), observation(value))
            self.assertEqual(len(result["stages"]), 12)
            for field in ["executionEnabled", "artifactVerificationExecuted", "nativeUIExecuted", "productionCompatibilityValidated", "publicReleaseValidated"]:
                self.assertIs(result[field], False)
            self.assertEqual(result["hostSources"], ["1" * 40, "2" * 40])

    def test_equal_host_source_or_normalized_code_cannot_become_update_proof(self):
        for key in ["source", "version", "normalizedUnsignedSHA256", "hostExecutableSHA256", "dmgSHA256"]:
            value = synthetic_request()
            value["hosts"]["current"][key] = value["hosts"]["previous"][key]
            with self.subTest(key=key), self.assertRaises(ValueError):
                COHORT.request(json.dumps(value))

    def test_missing_legacy_incompatible_or_unsigned_worker_contract_is_rejected(self):
        edits = [("schema", 1), ("helperExecutable", "missing"), ("uiExecutable", "bin/full-host"), ("signatureVerified", False), ("packagedHostRequirement", "foreign requirement"), ("carrierInputSHA256", "")]
        for generation in ["previous", "current"]:
            for key, changed in edits:
                value = synthetic_request()
                value["packages"][generation]["workerContract"][key] = changed
                with self.subTest(generation=generation, key=key), self.assertRaises(ValueError):
                    COHORT.request(json.dumps(value))
            value = synthetic_request()
            del value["packages"][generation]["workerContract"]
            with self.assertRaises(ValueError):
                COHORT.request(json.dumps(value))

    def test_host_signer_requirement_architecture_and_abi_must_match_both_packages(self):
        for key, changed in [("teamIdentifier", "KLMNOPQRST"), ("designatedRequirement", 'identifier "com.pulkit.edith" and anchor apple generic and certificate leaf[subject.OU] = "KLMNOPQRST"'), ("certificateCategory", "Developer ID Application"), ("architecture", "x86_64"), ("hostABI", "edith-host-1")]:
            value = synthetic_request()
            value["hosts"]["current"][key] = changed
            with self.subTest(key=key), self.assertRaises(ValueError):
                COHORT.request(json.dumps(value))

    def test_public_receipt_claims_are_required_but_never_treated_as_executed_verification(self):
        for key, changed in [("publicationVerified", False), ("sparkleEd25519Verified", False), ("deepStrictSignatureVerified", False), ("dmgURL", "https://untrusted.example/Edith.dmg"), ("notarization", "unknown"), ("dmgBytes", 2 * 1024**3 + 1), ("extensionPayloadBytes", 1), ("normalizedUnsignedSHA256", "1" * 64 + "\n")]:
            value = synthetic_request()
            value["hosts"]["previous"][key] = changed
            with self.subTest(key=key), self.assertRaises(ValueError):
                COHORT.request(json.dumps(value))
        self.assertIs(COHORT.execution_plan(synthetic_request())["artifactVerificationExecuted"], False)

    def test_duplicate_extra_missing_and_unbounded_request_fields_reject(self):
        value = synthetic_request()
        text = json.dumps(value)
        for changed in [text[:-1] + ', "source": "' + "b" * 40 + '"}', text.replace('"schema": 2', '"schema": 2, "schema": 1', 1), json.dumps({**value, "environment": {"HOME": "/foreign"}}), json.dumps({key: item for key, item in value.items() if key != "hosts"}), " " * 65537]:
            with self.assertRaises(ValueError):
                COHORT.request(changed)

    def test_preexisting_app_preferences_data_processes_or_noncanonical_home_reject(self):
        value = synthetic_request()
        for key, changed in [("application", "/tmp/Edith.app"), ("canonicalHome", "/Users/another"), ("effectiveUID", 502), ("existingProductionProcesses", 1), ("inputsVerified", False), ("accountHome", "/Users/synthetic/../real")]:
            observed = observation(value)
            observed[key] = changed
            with self.subTest(key=key), self.assertRaises(ValueError):
                COHORT.admit_plan(value, environment(), observed)
        for index in range(len(observation(value)["absentPaths"])):
            observed = observation(value)
            del observed["absentPaths"][index]
            with self.assertRaises(ValueError):
                COHORT.admit_plan(value, environment(), observed)

    def test_wrong_owner_source_event_and_identity_or_interpreter_overrides_reject(self):
        value = synthetic_request()
        for key, changed in [("GITHUB_ACTOR_ID", "1"), ("GITHUB_SHA", "b" * 40), ("GITHUB_REF", "refs/heads/fixture"), ("GITHUB_EVENT_NAME", "pull_request"), ("PUBLISH", "true"), ("PYTHONPATH", "/foreign"), ("NODE_OPTIONS", "--require=foreign"), ("EDITH_APPLICATION_IDENTIFIER", "com.pulkit.edith.tests"), ("EDITH_FIXTURE_HOME", "/foreign"), ("CFFIXED_USER_HOME", "/foreign")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                COHORT.admit_plan(value, {**environment(), key: changed}, observation(value))

    def test_live_catalog_must_select_retained_before_real_promotion(self):
        value = synthetic_request()
        observed = observation(value)
        observed["initialCatalog"] = value["catalogs"]["current"]
        with self.assertRaises(ValueError):
            COHORT.admit_plan(value, environment(), observed)
        for generation in ["previous", "current"]:
            changed = copy.deepcopy(value)
            changed["catalogs"][generation]["selectedVersion"] = "9.9.9"
            with self.assertRaises(ValueError):
                COHORT.request(json.dumps(changed))

    def test_plan_contains_only_normal_cli_and_original_ui_without_success_flags(self):
        plan = COHORT.execution_plan(synthetic_request())
        names = [row["name"] for row in plan["stages"]]
        self.assertLess(names.index("verify-public-inputs"), names.index("install-public-host-A"))
        self.assertLess(names.index("observe-host-B-restoration"), names.index("update-Keep"))
        for row in plan["stages"]:
            if row["command"]:
                self.assertEqual(row["command"][0], COHORT.CLI)
                self.assertEqual(row["command"][-1], "--json")
                self.assertNotIn("--timeout", row["command"])
                self.assertNotIn("--version", row["command"])
            self.assertGreater(len(row["requiredObservations"]), 0)
        serialized = json.dumps(plan)
        self.assertNotIn("com.pulkit.edith.tests", serialized)
        self.assertNotIn("EDITH_", serialized)
        self.assertNotIn("kill", serialized)


if __name__ == "__main__":
    unittest.main()
