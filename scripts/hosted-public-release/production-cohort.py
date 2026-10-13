import json
import re
from urllib.parse import quote


APPLICATION = "/Applications/Edith.app"
EXECUTABLE = APPLICATION + "/Contents/MacOS/Edith"
CLI = EXECUTABLE
SHA = re.compile(r"[a-f0-9]{64}\Z")
COMMIT = re.compile(r"[a-f0-9]{40}\Z")
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def exact(value, keys):
    require(type(value) is dict and set(value) == set(keys), "Unexpected cohort fields")


def positive(value, maximum=2**53 - 1):
    require(type(value) is int and 0 < value <= maximum, "Invalid bounded count")


def digest(value):
    require(type(value) is str and SHA.fullmatch(value), "Invalid digest")


def source(value):
    require(type(value) is str and COMMIT.fullmatch(value), "Invalid source")


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, "Duplicate cohort key")
        value[key] = item
    return value


def request(text):
    return validated_request(text, False)


def preparation_template(text):
    return validated_request(text, True)


def validated_request(text, preparation):
    require(type(text) is str and 0 < len(text.encode()) <= 65536, "Unbounded cohort request")
    value = json.loads(text, object_pairs_hook=unique_object)
    exact(value, ["schema", "source", "application", "hosts", "packages", "catalogs"])
    require(value["schema"] == 1 and type(value["schema"]) is int, "Invalid cohort schema")
    source(value["source"])
    require(value["application"] == APPLICATION, "Production application must be canonical")
    for kind in ["hosts", "packages", "catalogs"]:
        exact(value[kind], ["previous", "current"])
    if preparation:
        require(value["packages"]["current"] is None and value["catalogs"]["current"] is None, "Current package and catalog must be measured")
    for generation in ["previous", "current"]:
        host(value["hosts"][generation])
        if preparation and generation == "current":
            continue
        package(value["packages"][generation], "1.0.0" if generation == "previous" else "1.0.1")
        catalog(value["catalogs"][generation], value["packages"][generation])
    previous = value["hosts"]["previous"]
    current = value["hosts"]["current"]
    for key in ["source", "version", "normalizedUnsignedSHA256", "hostExecutableSHA256", "dmgSHA256"]:
        require(previous[key] != current[key], "Host implementation or release did not change")
    require(tuple(map(int, current["version"].split("."))) > tuple(map(int, previous["version"].split("."))), "Host update is not newer")
    require(current["build"] > previous["build"], "Host build is not newer")
    for key in ["teamIdentifier", "designatedRequirement", "hostABI", "architecture", "certificateCategory"]:
        require(previous[key] == current[key], "Host trust or worker compatibility changed")
    for generation in (["previous"] if preparation else ["previous", "current"]):
        item = value["packages"][generation]
        for key in ["hostABI", "architecture"]:
            require(item[key] == previous[key], "Package is incompatible with either host")
        require(item["workerContract"]["packagedHostRequirement"] == previous["designatedRequirement"], "Package does not authenticate both production hosts")
    if not preparation:
        older = value["packages"]["previous"]
        newer = value["packages"]["current"]
        for key in ["archiveSHA256", "sourceFingerprint"]:
            require(older[key] != newer[key], "Package generation did not change")
        require(value["catalogs"]["current"]["revision"] > value["catalogs"]["previous"]["revision"], "Catalog did not advance")
        require(value["catalogs"]["current"]["sha256"] != value["catalogs"]["previous"]["sha256"], "Catalog bytes did not change")
    return value


def host(value):
    exact(value, ["source", "run", "tag", "version", "build", "proofSHA256", "dmgURL", "dmgSHA256", "dmgBytes", "appcastSHA256", "hostExecutableSHA256", "normalizedUnsignedSHA256", "normalization", "installedBytes", "extensionPayloadBytes", "hostABI", "architecture", "teamIdentifier", "certificateCategory", "designatedRequirement", "deepStrictSignatureVerified", "sparkleEd25519Verified", "notarization", "publicationVerified"])
    source(value["source"])
    positive(value["run"])
    require(type(value["version"]) is str and VERSION.fullmatch(value["version"]), "Invalid host version")
    require(value["tag"] == "v" + value["version"], "Release tag mismatch")
    positive(value["build"])
    for key in ["proofSHA256", "dmgSHA256", "appcastSHA256", "hostExecutableSHA256", "normalizedUnsignedSHA256"]:
        digest(value[key])
    positive(value["dmgBytes"], 2 * 1024**3)
    positive(value["installedBytes"], 2 * 1024**3)
    require(type(value["extensionPayloadBytes"]) is int and value["extensionPayloadBytes"] == 0, "Host contains optional payload")
    prefix = "https://github.com/pulkitxm/edith/releases/download/" + value["tag"] + "/"
    require(type(value["dmgURL"]) is str and re.fullmatch(re.escape(prefix) + r"[A-Za-z0-9._-]+\.dmg", value["dmgURL"]), "Not an immutable public host release")
    require(value["normalization"] == "arm64-terminal-linkedit-vmsize-after-verified-signature-removal-v1", "Unknown code normalization")
    require(value["hostABI"] == "edith-host-2" and value["architecture"] == "arm64", "Legacy or unsupported host")
    require(type(value["teamIdentifier"]) is str and re.fullmatch(r"[A-Z0-9]{10}", value["teamIdentifier"]), "Invalid signing team")
    require(value["certificateCategory"] in ["Developer ID Application", "Apple Development", "Apple Distribution"], "Unsupported signing class")
    requirement = value["designatedRequirement"]
    require(type(requirement) is str and 0 < len(requirement.encode()) <= 4096 and "\n" not in requirement and "\r" not in requirement, "Invalid signing requirement")
    require('identifier "com.pulkit.edith"' in requirement and value["teamIdentifier"] in requirement , "Unbound production signing requirement")
    for key in ["deepStrictSignatureVerified", "sparkleEd25519Verified", "publicationVerified"]:
        require(value[key] is True, "Public host verification missing")
    require(value["notarization"] in ["verified", "skipped"], "Unknown notarization result")


def package(value, version):
    exact(value, ["id", "source", "run", "version", "archiveURL", "archiveSHA256", "downloadBytes", "installedBytes", "sourceFingerprint", "hostABI", "architecture", "minimumSystemVersion", "dependencies", "workerContract"])
    require(value["id"] == "keepAwake" and value["version"] == version, "Wrong public Keep generation")
    source(value["source"])
    positive(value["run"])
    for key in ["archiveSHA256", "sourceFingerprint"]:
        digest(value[key])
    for key in ["downloadBytes", "installedBytes"]:
        positive(value[key], 2 * 1024**3)
    require(value["hostABI"] == "edith-host-2" and value["architecture"] == "arm64" and value["minimumSystemVersion"] == "14.0.0", "Unsupported Keep contract")
    require(value["dependencies"] == [], "Unexpected Keep dependencies")
    tag = f"extensions/keepAwake/{version}-{value['sourceFingerprint'][:20]}"
    require(value["archiveURL"] == "https://github.com/pulkitxm/edith/releases/download/" + quote(tag, safe="") + "/keepAwake.zip", "Not an immutable public Keep archive")
    worker = value["workerContract"]
    exact(worker, ["schema", "carrierInputSHA256", "frozenHostSHA256", "packagedHostRequirement", "helperExecutable", "uiExecutable", "helperSHA256", "uiSHA256", "carrierSHA256", "signatureVerified"])
    require(type(worker["schema"]) is int and worker["schema"] == 2, "Missing current carrier contract")
    for key in ["carrierInputSHA256", "frozenHostSHA256", "helperSHA256", "uiSHA256", "carrierSHA256"]:
        digest(worker[key])
    require(worker["helperExecutable"] == "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/keepAwake/helper.bundle/Contents/MacOS/Runtime" and worker["uiExecutable"] == "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/MacOS/Edith", "Missing or legacy worker implementation")
    require(worker["signatureVerified"] is True, "Worker signature proof missing")


def catalog(value, selected):
    exact(value, ["revision", "sha256", "bytes", "signatureVerified", "selectedVersion", "selectedArchiveSHA256"])
    positive(value["revision"])
    positive(value["bytes"], 3 * 1024**2)
    digest(value["sha256"])
    require(value["signatureVerified"] is True, "Unsigned catalog")
    require(value["selectedVersion"] == selected["version"] and value["selectedArchiveSHA256"] == selected["archiveSHA256"], "Normal installer would select another generation")


def hosted(environment, expected):
    for key, value in {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS", "GITHUB_REPOSITORY": "pulkitxm/edith", "GITHUB_REPOSITORY_ID": "1289153439", "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": expected, "PUBLIC_RELEASE_VERIFICATION": "1", "PUBLISH": "false", "REBUILD": ""}.items():
        require(environment.get(key) == value, "Unreviewed hosted production cohort")
    require(environment.get("GITHUB_ACTOR_ID") in ["65671483", "320458784"], "Wrong hosted owner")
    forbidden = ["PYTHONPATH", "PYTHONHOME", "NODE_OPTIONS", "NODE_PATH", "CFFIXED_USER_HOME", "SSH_AUTH_SOCK"]
    require(not any(environment.get(key) for key in forbidden), "Ambient production override")
    require(not any(key.startswith("EDITH_") for key in environment), "Fixture identity or path override")


def preflight(value):
    exact(value, ["application", "accountHome", "effectiveUID", "realUID", "canonicalHome", "absentPaths", "existingProductionProcesses", "inputsVerified", "initialCatalog"])
    require(value["application"] == APPLICATION, "Wrong installed application")
    home = value["accountHome"]
    require(type(home) is str and re.fullmatch(r"/Users/[A-Za-z0-9_-]+", home), "Noncanonical hosted home")
    require(value["canonicalHome"] == home, "Home is not canonical")
    positive(value["effectiveUID"], 2**32 - 1)
    require(value["effectiveUID"] == value["realUID"], "UID changed")
    expected = [APPLICATION] + [home + suffix for suffix in ["/Library/Application Support/Edith", "/Library/Caches/Edith", "/Library/Logs/Edith", "/Library/Preferences/com.pulkit.edith.plist", "/Library/Preferences/com.pulkit.edith.host.plist", "/Library/Preferences/com.pulkit.edith.shared.plist"]]
    require(value["absentPaths"] == expected, "Production state or application already exists")
    require(type(value["existingProductionProcesses"]) is int and value["existingProductionProcesses"] == 0, "Existing production owner")
    require(value["inputsVerified"] is True, "Artifact verification must precede launch")
    return value


def execution_plan(value):
    value = request(json.dumps(value))
    old = value["packages"]["previous"]
    stages = [
        ("verify-public-inputs", [], ["source-bound-run-success", "immutable-download-hashes", "DMG-Sparkle-signatures", "deep-strict-designated-requirement", "normalized-code-inequality", "current-worker-contracts", "signed-catalogs"]),
        ("admit-fresh-production-user", [], ["canonical-Applications-path", "all-production-state-absent", "no-existing-production-processes", "kernel-owned-host-process-observer"]),
        ("install-public-host-A", [], ["unchanged-public-DMG-installation", "actual-installed-A-executable-and-code-identity", "normal-production-application-start"]),
        ("install-previous-Keep", [CLI, "extensions", "install", "keepAwake", "--json"], ["live-catalog-selects-1.0.0", "exact-public-1.0.0-installed-bytes"]),
        ("enable-previous-Keep", [CLI, "extensions", "enable", "keepAwake", "--json"], ["owned-engine-current-UID-birth-path-CDHash", "retained-1.0.0-selection"]),
        ("save-original-UI-state", [], ["original-native-UI-control-actions", "saved-layout-and-selected-Keep-generation", "real-original-toggle-press-true", "three-real-IOKit-state-transitions", "owned-managed-UI-identity"]),
        ("perform-original-Sparkle-host-update", [], ["normal-original-update-UI", "actual-public-B-appcast-and-DMG", "joined-A-host-engine-UI-drain", "no-old-generation-survivors", "unchanged-canonical-installation-path"]),
        ("observe-host-B-restoration", [CLI, "extensions", "info", "keepAwake", "--json"], ["actual-B-signed-unequal-code-identity", "old-1.0.0-generation-retained-without-reinstall", "restored-layout-selection-engine-and-original-UI", "strict-B-host-A-package-authentication"]),
        ("observe-public-catalog-promotion", [], ["live-signed-current-catalog", "current-catalog-selects-1.0.1", "no-local-catalog-overrides"]),
        ("update-Keep", [CLI, "extensions", "update", "keepAwake", "--json"], ["exact-public-1.0.1-installed-bytes", "normal-compatible-generation-update"]),
        ("observe-package-restoration", [CLI, "extensions", "info", "keepAwake", "--json"], ["saved-layout-selection-and-engine-restored", "old-package-owner-drain", "original-UI-and-real-IOKit-toggle"]),
        ("quit-and-join-owned-production-processes", [], ["normal-application-quit", "strict-same-UID-birth-path-CDHash-ownership", "zero-owned-survivors", "no-unidentified-process-signals"]),
    ]
    return {"schema": 1, "source": value["source"], "application": APPLICATION, "mode": "nonpublishing-public-host-cohort-plan", "hostSources": [value["hosts"][generation]["source"] for generation in ["previous", "current"]], "retainedArchiveSHA256": old["archiveSHA256"], "stages": [{"name": name, "command": command, "requiredObservations": observations} for name, command, observations in stages], "budgetPolicy": "existing-hosted-public-release-and-original-UI-deadlines", "executionEnabled": False, "artifactVerificationExecuted": False, "nativeUIExecuted": False, "productionCompatibilityValidated": False, "publicReleaseValidated": False, "pending": ["actual-public-input-verification", "kernel-owned-production-process-observer", "ordinary-CLI-and-native-UI-executor", "two-genuinely-different-qualifying-public-host-releases"]}


def admit_plan(value, environment, observation):
    value = request(json.dumps(value))
    hosted(environment, value["source"])
    preflight(observation)
    require(observation["initialCatalog"] == value["catalogs"]["previous"], "Initial normal install cannot select retained Keep")
    return execution_plan(value)
