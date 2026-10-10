import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import subprocess
from pathlib import Path


BUILD_FIELDS = ("sourceCommit", "configuration", "optimization", "architecture", "signature", "xcode", "sdk", "ghosttySourceCommit", "ghosttyArchive")


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


def build_report(baseline, app, packages, definitions, index, expected_fingerprints=None, host_build=None):
    migrated = [entry["id"] for entry in definitions if entry.get("contractVersion") == 1]
    known = {entry["id"] for entry in index}
    if not index or len(known) != len(index) or len(set(migrated)) != len(migrated) or not set(migrated).issubset(known):
        raise ValueError("Migrated extensions must belong to the host index")
    if expected_fingerprints is not None:
        for identifier in migrated:
            metadata = json.loads((packages / f"{identifier}.json").read_text())
            if not expected_fingerprints.get(identifier) or metadata.get("sourceFingerprint") != expected_fingerprints[identifier]:
                raise ValueError(f"Rebuild {identifier} before measuring: its source fingerprint is stale")
    specification = importlib.util.spec_from_file_location("size_measurements", Path(__file__).with_name("extension-size-report.py"))
    measurements = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(measurements)
    measured = measurements.measure_app(app)
    executable_hash = hashlib.sha256((app / "Contents/MacOS/Edith").read_bytes()).hexdigest()
    if host_build is not None and host_build.get("hostExecutableSHA256") != executable_hash:
        raise ValueError("Host build metadata must match the measured executable checksum")
    result = measurements.compare(baseline, measured, measurements.measure_packages(packages, migrated))
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
        "baselineSourceCommit": baseline["sourceCommit"],
        "baselineBuild": {key: baseline[key] for key in BUILD_FIELDS if key in baseline},
        "hostBuild": {key: host_build[key] for key in BUILD_FIELDS if key in (host_build or {})},
        "packageSource": "local-build-artifacts",
        "artifactPublication": "not-verified",
        "sourceFingerprintsVerified": expected_fingerprints is not None,
        "appZipMethod": "Regular files only, symlinks excluded, ZIP deflate level 9. Comparison metric, not a shipping installer.",
        "installedMethod": "Logical regular-file bytes, excluding filesystem allocation rounding, receipts, caches, user data, retained versions and OS-managed deployment copies.",
        "verificationScope": "Package archive size, SHA-256, expanded bytes and CRC. Source fingerprints when supplied. This report does not run lifecycle, visual, signing or cloud publication checks.",
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
        "sourceCommit": "source commit", "configuration": "configuration",
        "optimization": "optimization", "architecture": "architecture",
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

Measured on {report['measuredAtUTC'].split('T')[0]}. {coverage} Package coverage describes the measured artifacts. It does not establish merge readiness, lifecycle test results, visual review, production signing, or release publication.

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

The generator verifies each package's ZIP size, SHA-256, expanded bytes and CRC. {fingerprint_check} The recorded host executable checksum identifies the exact measured binary. The size calculation does not verify code signatures, the host dependency boundary, zero feature payload, lifecycle behavior, card adapters, platform installation, or cloud release behavior. Record those results separately from the measurement.

Worker lifecycle verification covers the owning Edith worker, admitted same-host native tasks, and registered command or descendant process groups. Process-group teardown uses live kernel birth identities. Arbitrarily detached, unregistered feature processes are outside this ownership contract. Camera uses an independently installed OBS Virtual Camera provider, which Edith does not install, remove, or deactivate. Disabling Camera stops its capture and frame delivery. The optional meeting-microphone driver has separate retirement rules and can require a macOS restart. Approval or restart-required retirement must remain visible and keep ownership recoverable. A worker reaching zero processes does not prove that an OS-managed provider or loaded driver has retired.

Home and Notch customization from merged [PR #1010](https://github.com/pulkitxm/edith/pull/1010) uses host-owned layouts and a versioned worker boundary. Size measurements do not validate live card data, actions, cancellation, privacy behavior, or visual editor layouts. Editor sample previews are labeled explicitly; live preview queries already running providers. Run and review synthetic lifecycle and visual fixtures separately for the final integrated feature set.

Exact byte counts, package checksums, and the host executable checksum are in [the measurement data](extension-host-rebuild-size-report.json). See [the measurement procedure](extension-host-rebuild-measurements.md) for build provenance, publication limits and platform retirement checks. After building the final integrated host and every indexed package, regenerate both reports:

```sh
make ci-marketplace-host
make ci-extension-workers EXTENSION=--retain-packages
make shipping-fixture HOST_FIXTURE=local/minimal-host/Edith.app
python3 -B scripts/extension-host-size-report.py --baseline local/baseline/current-main-size.json --app local/shipping-fixture/Edith.app --host-build local/shipping-fixture/build-metadata.json --output docs/extension-host-rebuild-size-report.json --markdown-output docs/extension-host-rebuild-size-report.md
```

The baseline source commit is `{report['measurement']['baselineSourceCommit']}`. Host build metadata is accepted only when its executable checksum matches the measured binary. Omit `--host-build` when provenance has not been recorded; the report will say so instead of assuming a configuration or signing identity. The empty-host limit remains enforced by the build and shipping verifier, independently of this report.
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--app", type=Path, default=Path("local/minimal-host/Edith.app"))
    parser.add_argument("--packages", type=Path, default=Path("dist/extensions"))
    parser.add_argument("--host-build", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--markdown-output", type=Path)
    arguments = parser.parse_args()
    fingerprints = json.loads(subprocess.run(["bun", str(Path(__file__).with_name("extension-artifact-fingerprints.mjs"))], check=True, capture_output=True, text=True).stdout)
    index = json.loads(Path("Packages/EdithHost/Sources/EdithHostCore/Resources/index.json").read_text())
    host_build = json.loads(arguments.host_build.read_text()) if arguments.host_build else None
    report = build_report(json.loads(arguments.baseline.read_text()), arguments.app, arguments.packages, json.loads(Path("Extensions/manifest.json").read_text()), index, fingerprints, host_build)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    if arguments.markdown_output:
        arguments.markdown_output.parent.mkdir(parents=True, exist_ok=True)
        arguments.markdown_output.write_text(render_markdown(report, index))


if __name__ == "__main__":
    main()
