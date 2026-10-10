import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import re
import subprocess
from pathlib import Path, PurePosixPath
import os
import plistlib
import shutil
import stat
import tempfile
import uuid
import zipfile


BUILD_FIELDS = ("sourceCommit", "sourceTreeDirty", "configuration", "optimization", "linkTimeOptimization", "architecture", "signature", "xcode", "sdk", "ghosttySourceCommit", "ghosttyArchive")


def measure_host_components(app):
    components = dict.fromkeys(("hostAndCLI", "appUpdater", "resources", "bundleMetadata"), 0)
    for path in app.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        parts = path.relative_to(app).parts
        if parts[:2] == ("Contents", "MacOS"):
            component = "hostAndCLI"
        elif parts[:3] == ("Contents", "Frameworks", "Sparkle.framework"):
            component = "appUpdater"
        elif parts[:2] == ("Contents", "Resources"):
            component = "resources"
        else:
            component = "bundleMetadata"
        components[component] += path.stat().st_size
    return components


def measure_scenarios(host, packages):
    by_id = {entry["id"]: entry for entry in packages}
    scenarios = [
        ("Daily tools", ["calendar", "clipboard", "systemStats", "usage"]),
        ("Development tools", ["terminal", "database", "docs", "codeStats"]),
        ("Media tools", ["virtualCamera", "studio", "audioMixer", "music", "timeLapse"]),
    ]
    return [
        {"name": name, "extensions": identifiers,
         "installedBytes": host["installedBytes"] + sum(by_id[identifier]["installedBytes"] for identifier in identifiers),
         "extensionDownloadBytes": sum(by_id[identifier]["downloadBytes"] for identifier in identifiers)}
        for name, identifiers in scenarios if all(identifier in by_id for identifier in identifiers)
    ]


def read_source_state(root):
    commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, check=True, capture_output=True, text=True).stdout.strip()
    changes = subprocess.run(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=root, check=True, capture_output=True, text=True).stdout
    return {"sourceCommit": commit, "sourceTreeDirty": bool(changes)}


def validate_final_source(expected_commit, source_state, host_build):
    if not re.fullmatch(r"[0-9a-f]{40}", expected_commit or ""):
        raise ValueError("Final reports require an explicit full expected source commit")
    for name, metadata in [("Current source", source_state), ("Host build", host_build)]:
        if not metadata or metadata.get("sourceCommit") != expected_commit or metadata.get("sourceTreeDirty") is not False:
            raise ValueError(f"{name} must match the expected source commit and be clean")


def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def unsigned_executable_digest(path):
    with tempfile.TemporaryDirectory(prefix="extension-report-code-") as directory:
        copied = Path(directory) / "Edith"
        shutil.copyfile(path, copied)
        subprocess.run(["codesign", "--remove-signature", str(copied)], check=True,
            capture_output=True, timeout=30)
        return digest_file(copied)


def tree_inventory(directory):
    inventory = {}
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory).as_posix()
        if path.is_symlink():
            inventory[relative] = {"symlink": os.readlink(path)}
        elif path.is_file():
            inventory[relative] = {"sha256": digest_file(path), "mode": stat.S_IMODE(path.stat().st_mode)}
        elif not path.is_dir():
            raise ValueError("Host provenance contains a nonregular resource")
    return inventory


def validate_camera_clone(receipt, app, expected_commit, host_hash, unsigned_hash):
    source = app.resolve()
    clone = Path(receipt.get("clone", "")).resolve()
    if (receipt.get("schema") != 1 or receipt.get("sourceCommit") != expected_commit
            or receipt.get("sourceHost") != str(source) or receipt.get("sourceExecutableSHA256") != host_hash
            or receipt.get("executableBeforeSigningSHA256") != host_hash):
        raise ValueError("Camera clone must bind the exact frozen host and source commit")
    if source == clone or source in clone.parents or clone in source.parents or Path(receipt["clone"]).is_symlink():
        raise ValueError("Camera clone must be separate from the frozen host")
    if tree_inventory(source) != receipt.get("sourceInventory") or tree_inventory(clone) != receipt.get("cloneInventory"):
        raise ValueError("Camera clone or frozen resource inventory changed")
    source_info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    clone_info = plistlib.loads((clone / "Contents/Info.plist").read_bytes())
    identifier = receipt.get("identifier", "")
    prefix = "com.pulkit.edith.tests.camera-build-"
    if not identifier.startswith(prefix):
        raise ValueError("Camera clone requires a synthetic identity")
    try:
        uuid.UUID(identifier.removeprefix(prefix))
    except ValueError as error:
        raise ValueError("Camera clone synthetic identity is malformed") from error
    if clone_info != {**source_info, "CFBundleIdentifier": identifier}:
        raise ValueError("Camera clone changed more than its bundle identity")
    allowed = {"Contents/Info.plist", "Contents/MacOS/Edith"}
    resources = [{key: value for key, value in receipt[field].items()
                  if key not in allowed and not key.startswith("Contents/_CodeSignature/")}
                 for field in ["sourceInventory", "cloneInventory"]]
    if resources[0] != resources[1]:
        raise ValueError("Camera clone resources differ from the frozen host")
    executable = clone / "Contents/MacOS/Edith"
    if (digest_file(executable) != receipt.get("executableAfterSigningSHA256")
            or receipt.get("unsignedExecutableSHA256") != unsigned_hash
            or unsigned_executable_digest(executable) != unsigned_hash):
        raise ValueError("Camera clone executable differs from the frozen host code")
    return receipt


def read_archive_document(zipped, name, parser):
    if zipped.getinfo(name).file_size > 1024 * 1024:
        raise ValueError("Carrier metadata exceeds the document limit")
    return parser(zipped.read(name))


def verify_package_host(packages, metadata, definition, app, expected_commit, host_hash, unsigned_hash):
    identifier = metadata["id"]
    expected_hash = host_hash
    clone = None
    clone_path = packages / f"{identifier}.synthetic-host-provenance.json"
    if clone_path.exists():
        if identifier != "virtualCamera":
            raise ValueError("Synthetic host provenance is permitted only for Camera")
        clone = validate_camera_clone(json.loads(clone_path.read_text()), app, expected_commit, host_hash, unsigned_hash)
        expected_hash = clone["executableAfterSigningSHA256"]
    host_identifier = clone["identifier"] if clone else plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
    result = {"sourceCommit": expected_commit, "sourceHostExecutableSHA256": host_hash,
              "unsignedExecutableSHA256": unsigned_hash, "executables": []}
    if clone:
        result["syntheticHost"] = {key: clone[key] for key in ["identifier", "sourceCommit", "sourceExecutableSHA256",
            "executableBeforeSigningSHA256", "executableAfterSigningSHA256", "unsignedExecutableSHA256"]}
        result["syntheticHostReceiptSHA256"] = digest_file(clone_path)
    carrier = f"{identifier}/ExtensionCarrier.app"
    worker = f"{carrier}/Contents/Extensions/ExtensionWorker.appex"
    nested = f"{worker}/Contents/Resources/Payload/{identifier}"
    with zipfile.ZipFile(packages / f"{identifier}.zip") as zipped:
        infos = zipped.infolist()
        names = {info.filename for info in infos}
        if len(names) != len(infos):
            raise ValueError("Package archive contains duplicate members")
        for info in infos:
            path = PurePosixPath(info.filename)
            if (path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != identifier
                    or "\\" in info.filename or "\0" in info.filename
                    or stat.S_IFMT(info.external_attr >> 16) == stat.S_IFLNK):
                raise ValueError("Package archive contains an unsafe member")
        manifest = read_archive_document(zipped, f"{nested}/package.json", json.loads)
        for key in ["id", "version", "hostABI", "architecture", "dependencies"]:
            if manifest.get(key) != metadata.get(key):
                raise ValueError("Sealed payload manifest differs from package metadata")
        if metadata.get("hostABI") != "edith-host-2" or metadata.get("architecture") != "arm64":
            raise ValueError("Final packages require current host ABI and architecture")
        if metadata.get("dependencies") != definition.get("dependencies", []):
            raise ValueError("Package dependencies differ from the current definition")
        carrier_infos = {bundle: read_archive_document(zipped, f"{bundle}/Contents/Info.plist", plistlib.loads)
                         for bundle in [carrier, worker]}
        for info in carrier_infos.values():
            if (info.get("EdithExtensionID") != identifier or info.get("EdithExtensionVersion") != metadata["version"]
                    or info.get("EdithHostABI") != metadata["hostABI"]):
                raise ValueError("Sealed UI carrier identity, version or ABI differs from the package")
        if any(carrier_infos[carrier].get(key) != carrier_infos[worker].get(key)
               for key in ["EdithHostIdentifier", "EdithExecutableProvenance"]):
            raise ValueError("Sealed UI carrier and worker host provenance differ")
        if any(info.get("EdithHostIdentifier") != host_identifier for info in carrier_infos.values()):
            raise ValueError("UI carrier identity differs from its source-bound host")
        copied = {}
        contained_roles = {}
        for name in sorted(names):
            if not name.endswith("/Contents/Info.plist"):
                continue
            info = read_archive_document(zipped, name, plistlib.loads)
            if "EdithExecutableProvenance" not in info:
                continue
            bundle = name.removesuffix("/Contents/Info.plist")
            executable_name = info.get("CFBundleExecutable")
            if executable_name != "Edith" or info.get("EdithExecutableProvenance") != expected_hash:
                raise ValueError("Contained executable provenance differs from the frozen host")
            if info.get("EdithHostABI") != metadata["hostABI"] or info.get("EdithHostIdentifier") != host_identifier:
                raise ValueError("Contained executable ABI or host identity differs")
            role_name = info.get("EdithContainedRole")
            if role_name:
                if identifier != "virtualCamera" or role_name in contained_roles or info.get("EdithContainedExtensionID") != identifier:
                    raise ValueError("Contained role identity is ambiguous")
                contained_roles[role_name] = bundle
            executable = f"{bundle}/Contents/MacOS/{executable_name}"
            with tempfile.TemporaryDirectory(prefix="extension-report-member-") as directory:
                target = Path(directory) / "Edith"
                with zipped.open(executable) as source, target.open("wb") as destination:
                    shutil.copyfileobj(source, destination, 1024 * 1024)
                actual_hash = digest_file(target)
                if unsigned_executable_digest(target) != unsigned_hash:
                    raise ValueError("Contained executable code differs from the frozen host")
            copied[bundle] = {"member": executable, "sha256": actual_hash,
                "installedBytes": zipped.getinfo(executable).file_size, "frozenExecutableProvenance": expected_hash}
            result["executables"].append(copied[bundle])
        if not {carrier, worker}.issubset(copied):
            raise ValueError("Both sealed UI carrier executable copies are required")
        if "cameraCarrier" in definition.get("roles", []):
            receipt = json.loads((packages / "virtualCamera.carrier-provenance.json").read_text())
            roles = receipt.get("roles", [])
            expected_roles = ["cameraCarrier"] if definition.get("systemExtensionCarrier", {}).get("transport") == "obs" else ["cameraCarrier", "cameraProvider"]
            if (receipt.get("schemaVersion") != 1 or receipt.get("hostABI") != metadata["hostABI"]
                    or receipt.get("version") != metadata["version"]
                    or receipt.get("hostIdentifier") != carrier_infos[carrier].get("EdithHostIdentifier")
                    or sorted(role.get("role", "") for role in roles) != sorted(expected_roles)):
                raise ValueError("Camera role provenance identity, version or roles differ")
            if set(contained_roles) != set(expected_roles) or contained_roles.get("cameraCarrier") != f"{nested}/CameraCarrier.app":
                raise ValueError("Camera sealed role inventory differs")
            for role in roles:
                bundle = contained_roles[role["role"]]
                if (bundle not in copied or role.get("executableBeforeSigningSHA256") != expected_hash
                        or role.get("executableAfterSigningSHA256") != copied[bundle]["sha256"]):
                    raise ValueError("Camera role executable differs from its signing provenance")
    return result


def build_report(baseline, app, packages, definitions, index, expected_fingerprints=None, host_build=None,
                 *, source_mode="final", expected_source_commit=None, source_state=None):
    migrated = [entry["id"] for entry in definitions if entry.get("contractVersion") == 1]
    known = {entry["id"] for entry in index}
    if not index or len(known) != len(index) or len(set(migrated)) != len(migrated) or not set(migrated).issubset(known):
        raise ValueError("Migrated extensions must belong to the host index")
    if source_mode not in {"final", "interim"}:
        raise ValueError("Unknown measurement source mode")
    if source_mode == "final":
        validate_final_source(expected_source_commit, source_state, host_build)
        if len(known) != 39 or set(migrated) != known or set(expected_fingerprints or {}) != known:
            raise ValueError("Final reports require exactly 39 indexed packages and current source fingerprints")
        if any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value) for value in expected_fingerprints.values()):
            raise ValueError("Final source fingerprints must be SHA-256 digests")
    metadata_by_id = {}
    for identifier in migrated:
        metadata = json.loads((packages / f"{identifier}.json").read_text())
        if metadata.get("id") != identifier:
            raise ValueError(f"Package metadata identity differs from its filename: {identifier}")
        metadata_by_id[identifier] = metadata
    if expected_fingerprints is not None:
        for identifier in migrated:
            metadata = metadata_by_id[identifier]
            if not expected_fingerprints.get(identifier) or metadata.get("sourceFingerprint") != expected_fingerprints[identifier]:
                raise ValueError(f"Rebuild {identifier} before measuring: its source fingerprint is stale")
    specification = importlib.util.spec_from_file_location("size_measurements", Path(__file__).with_name("extension-size-report.py"))
    measurements = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(measurements)
    measured = measurements.measure_app(app)
    executable_hash = digest_file(app / "Contents/MacOS/Edith")
    if host_build is not None and host_build.get("hostExecutableSHA256") != executable_hash:
        raise ValueError("Host build metadata must match the measured executable checksum")
    result = measurements.compare(baseline, measured, measurements.measure_packages(packages, migrated))
    result["packageHostProvenance"] = {}
    if source_mode == "final":
        unsigned_hash = unsigned_executable_digest(app / "Contents/MacOS/Edith")
        for definition in definitions:
            identifier = definition["id"]
            result["packageHostProvenance"][identifier] = verify_package_host(packages, metadata_by_id[identifier],
                definition, app, expected_source_commit, executable_hash, unsigned_hash)
        if digest_file(app / "Contents/MacOS/Edith") != executable_hash:
            raise ValueError("Measured host executable changed during provenance verification")
    result["sourceFingerprints"] = {identifier: metadata_by_id[identifier].get("sourceFingerprint") for identifier in sorted(migrated)}
    for package in result["packages"]:
        package["sourceFingerprint"] = result["sourceFingerprints"][package["id"]]
    result["hostComponents"] = measure_host_components(app)
    result["selectedExtensionScenarios"] = measure_scenarios(measured, result["packages"])
    result["migratedExtensionPackages"] = result.pop("allExtensionPackages")
    result["appWithMigratedExtensions"] = result.pop("appWithAllExtensions")
    remaining = sorted(known - set(migrated))
    result["measuredAtUTC"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    result["status"] = "partial-package-coverage" if remaining else "all-indexed-packages-measured"
    result["migratedExtensions"] = len(migrated)
    result["indexedExtensions"] = len(index)
    result["unmeasuredExtensions"] = remaining
    result["hostExecutableSHA256"] = executable_hash
    result["measurement"] = {
        "sourceMode": source_mode,
        "expectedSourceCommit": expected_source_commit,
        "currentSource": source_state or {},
        "baselineSourceCommit": baseline["sourceCommit"],
        "baselineBuild": {key: baseline[key] for key in BUILD_FIELDS if key in baseline},
        "hostBuild": {key: host_build[key] for key in BUILD_FIELDS if key in (host_build or {})},
        "packageSource": "local-build-artifacts",
        "artifactPublication": "not-verified",
        "sourceFingerprintsVerified": expected_fingerprints is not None,
        "carrierHostProvenanceVerified": source_mode == "final",
        "carrierExecutableMethod": "Sealed frozen-host provenance and SHA-256 of executable copies after signature removal in private temporary files. Actual signed checksums and expanded bytes remain recorded. Synthetic Camera hosts require a source-bound clone receipt and matching code and resources.",
        "appZipMethod": "Regular files only, symlinks excluded, ZIP deflate level 9. Comparison metric, not a shipping installer.",
        "installedMethod": "Logical regular-file bytes, excluding filesystem allocation rounding, receipts, caches, user data, retained versions and OS-managed deployment copies.",
        "verificationScope": "Package archive size, SHA-256, expanded bytes and CRC. Source fingerprints when supplied. Final reports also bind carrier code and source provenance. This report does not run lifecycle, visual, signing or cloud publication checks.",
    }
    result["surfaceCustomization"] = {
        "pullRequest": "https://github.com/pulkitxm/edith/pull/1010",
        "mergedCommit": "98a0f440e161c130f7ebd12a9da5dea42c38b238",
        "layoutContractVersion": 1,
        "verification": "not-measured-by-size-report",
    }
    return result


def describe_build(build):
    labels = {
        "sourceCommit": "source commit", "sourceTreeDirty": "uncommitted source changes", "configuration": "configuration",
        "optimization": "optimization", "linkTimeOptimization": "link-time optimization", "architecture": "architecture",
        "signature": "signing", "xcode": "Xcode", "sdk": "SDK",
        "ghosttySourceCommit": "Ghostty source commit", "ghosttyArchive": "Ghostty archive",
    }
    values = [f"{labels[key]}: `{build[key]}`" for key in BUILD_FIELDS if key in build]
    return "; ".join(values) if values else "Build configuration was not recorded"


def render_markdown(report, index):
    titles = {entry["id"]: entry["title"] for entry in index}
    count = report["migratedExtensions"]
    indexed = report["indexedExtensions"]
    host = report["appWithoutExtensions"]
    baseline = report["baseline"]
    combined = report["appWithMigratedExtensions"]
    totals = report["migratedExtensionPackages"]
    coverage = (
        f"All {indexed} indexed features have measured self-contained worker packages."
        if count == indexed
        else f"{count} of the {indexed} indexed features have measured self-contained worker packages. Unmeasured features: "
        + ", ".join(titles[identifier] for identifier in report["unmeasuredExtensions"]) + "."
    )
    rows = "\n".join(
        f"| {titles[entry['id']]} | {entry['downloadBytes']:,} | {entry['installedBytes']:,} | {entry['releaseMetadataBytes']:,} |"
        for entry in report["packages"]
    )
    fingerprint_check = (
        "The generator also matched each package's current source fingerprint."
        if report["measurement"]["sourceFingerprintsVerified"]
        else "Current package source fingerprints were not checked for this measurement."
    )
    saved = report['savedPercent']['installedBytes']
    savings = (
        f"The measured host is {saved:.2f}% smaller on disk than the recorded bundled-app baseline."
        if saved is not None else "A percentage reduction cannot be calculated from a zero-byte baseline."
    )
    component_labels = {
        "hostAndCLI": "Host and CLI", "appUpdater": "Sparkle app updater",
        "resources": "Icons, index and launcher resource", "bundleMetadata": "Bundle metadata and signatures",
    }
    component_rows = "\n".join(
        f"| {component_labels[key]} | {value:,} |" for key, value in report["hostComponents"].items()
    )
    scenario_rows = "\n".join(
        f"| {entry['name']} | {', '.join(entry['extensions'])} | {entry['installedBytes']/1_000_000:.2f} | {entry['extensionDownloadBytes']/1_000_000:.2f} |"
        for entry in report["selectedExtensionScenarios"]
    )
    return f"""# Lightweight host rebuild measurements

Measured on {report['measuredAtUTC'].split('T')[0]}. Source mode: `{report['measurement']['sourceMode']}`. {coverage} Package coverage describes the measured artifacts. It does not establish merge readiness, lifecycle test results, visual review, production signing, or release publication.

| Measured build | Installed MB | Comparison ZIP MB |
| --- | ---: | ---: |
| Recorded bundled-app baseline | {baseline['installedBytes']/1_000_000:.2f} | {baseline['comparisonZipBytes']/1_000_000:.2f} |
| Measured host without extension packages | {host['installedBytes']/1_000_000:.2f} | {host['comparisonZipBytes']/1_000_000:.2f} |
| Host plus all {count} measured extension packages | {combined['installedBytes']/1_000_000:.2f} | {combined['comparisonZipAndPackageBytes']/1_000_000:.2f} |

MB means 1,000,000 bytes. {savings} Comparison ZIPs use deflate level 9 over regular files and exclude symlinks. They are controlled comparison archives, not shipping installer sizes. The combined total counts the host and one installed package version per measured feature. OS-managed deployment copies, filesystem allocation rounding, receipts, caches, user data, and retained versions are excluded.

Baseline build: {describe_build(report['measurement']['baselineBuild'])}.

Host build: {describe_build(report['measurement']['hostBuild'])}.

| Empty host component | Installed bytes |
| --- | ---: |
{component_rows}
| Total empty host | {host['installedBytes']:,} |

The host contains the marketplace, window and surface layout controls, worker lifecycle and command gateway. Sparkle updates the application independently of extension updates. Downloaded feature code and resources belong to the packages below. Component sizes count each regular file once and exclude symbolic links.

| Example selection | Downloaded extensions | App plus installed packages MB | Extension download MB |
| --- | --- | ---: | ---: |
{scenario_rows}

These selections are size examples, not bundles or defaults. Each feature is downloaded separately. Installing every feature can cost more than the bundled app because independent packages duplicate shared runtime code and native libraries. The empty app and selected-package totals show the savings for people who install only the features they use.

| Local extension artifact | ZIP bytes | Installed package bytes | Package metadata bytes |
| --- | ---: | ---: | ---: |
{rows}
| All {count} measured packages | {totals['downloadBytes']:,} | {totals['installedBytes']:,} | {totals['releaseMetadataBytes']:,} |

The {count} local ZIPs plus their JSON metadata occupy {totals['releaseAssetBytes']:,} bytes. This subtotal does not include a shared signed catalog, detached checksums, older releases, or unmeasured packages. Measuring local artifacts neither publishes them nor proves that corresponding remote release assets exist. Publication status is not verified by this report.

The generator verifies each package's ZIP size, SHA-256, expanded bytes and CRC. {fingerprint_check} The recorded host executable checksum identifies the exact measured binary. Final reports bind sealed carrier metadata and signature-independent executable code to that frozen host and preserve each current package source fingerprint. Re-signed copies retain their actual signed checksums and expanded byte counts; these copies are already included in package totals. The size calculation does not verify code signatures, the host dependency boundary, zero feature payload, lifecycle behavior, card adapters, platform installation, or cloud release behavior. Record those results separately from the measurement.

Worker lifecycle verification covers the owning Edith worker, admitted same-host native tasks, and registered command or descendant process groups. Process-group teardown uses live kernel birth identities. Arbitrarily detached, unregistered feature processes are outside this ownership contract. Camera uses an independently installed OBS Virtual Camera provider, which Edith does not install, remove, or deactivate. Disabling Camera stops its capture and frame delivery. The optional meeting-microphone driver has separate retirement rules and can require a macOS restart. Approval or restart-required retirement must remain visible and keep ownership recoverable. A worker reaching zero processes does not prove that an OS-managed provider or loaded driver has retired.

Home and Notch customization from merged [PR #1010](https://github.com/pulkitxm/edith/pull/1010) uses host-owned layouts and a versioned worker boundary. Size measurements do not validate live card data, actions, cancellation, privacy behavior, or visual editor layouts. Editor sample previews are labeled explicitly; live preview queries already running providers. Run and review synthetic lifecycle and visual fixtures separately for the final integrated feature set.

Exact byte counts, package checksums, and the host executable checksum are in [the measurement data](extension-host-rebuild-size-report.json). See [the measurement procedure](extension-host-rebuild-measurements.md) for build provenance, publication limits and platform retirement checks. After building the final integrated host and every indexed package, regenerate both reports:

```sh
make ci-marketplace-host
make ci-extension-workers EXTENSION=--retain-packages
make shipping-fixture HOST_FIXTURE=local/minimal-host/Edith.app
python3 -B scripts/extension-host-size-report.py --source-mode final --expected-source-commit "$(git rev-parse HEAD)" --packages "$FINAL_PACKAGE_DIRECTORY" --baseline local/baseline/current-main-size.json --app local/shipping-fixture/Edith.app --host-build local/shipping-fixture/build-metadata.json --output docs/extension-host-rebuild-size-report.json --markdown-output docs/extension-host-rebuild-size-report.md
```

The baseline source commit is `{report['measurement']['baselineSourceCommit']}`. Final reports require an explicit expected source commit, a matching clean checkout and matching clean host build metadata. Host metadata must match the actual executable checksum. Use `--source-mode interim` for partial or historical measurements; missing build provenance remains explicitly unrecorded. The baseline retains its own recorded source commit and configuration. The empty-host limit remains enforced by the build and shipping verifier, independently of this report.
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--app", type=Path, default=Path("local/minimal-host/Edith.app"))
    parser.add_argument("--packages", type=Path, default=Path("dist/extensions"))
    parser.add_argument("--host-build", type=Path)
    parser.add_argument("--source-mode", choices=("final", "interim"), default="final")
    parser.add_argument("--expected-source-commit")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--markdown-output", type=Path)
    arguments = parser.parse_args()
    source_state = read_source_state(Path.cwd())
    if arguments.source_mode == "final":
        validate_final_source(arguments.expected_source_commit, source_state, json.loads(arguments.host_build.read_text()) if arguments.host_build else None)
    fingerprints = json.loads(subprocess.run(["bun", str(Path(__file__).with_name("extension-artifact-fingerprints.mjs"))], check=True, capture_output=True, text=True).stdout)
    index = json.loads(Path("Packages/EdithHost/Sources/EdithHostCore/Resources/index.json").read_text())
    host_build = json.loads(arguments.host_build.read_text()) if arguments.host_build else None
    report = build_report(json.loads(arguments.baseline.read_text()), arguments.app, arguments.packages, json.loads(Path("Extensions/manifest.json").read_text()), index, fingerprints, host_build,
        source_mode=arguments.source_mode, expected_source_commit=arguments.expected_source_commit, source_state=source_state)
    if arguments.source_mode == "final":
        validate_final_source(arguments.expected_source_commit, read_source_state(Path.cwd()), host_build)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    if arguments.markdown_output:
        arguments.markdown_output.parent.mkdir(parents=True, exist_ok=True)
        arguments.markdown_output.write_text(render_markdown(report, index))


if __name__ == "__main__":
    main()
