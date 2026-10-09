import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import subprocess
from pathlib import Path


def build_report(baseline, app, packages, definitions, index, expected_fingerprints=None):
    migrated = [entry["id"] for entry in definitions if entry.get("contractVersion") == 1]
    known = {entry["id"] for entry in index}
    if len(known) != len(index) or len(set(migrated)) != len(migrated) or not set(migrated).issubset(known):
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
    result = measurements.compare(baseline, measured, measurements.measure_packages(packages, migrated))
    result["migratedExtensionPackages"] = result.pop("allExtensionPackages")
    result["appWithMigratedExtensions"] = result.pop("appWithAllExtensions")
    result["measuredAtUTC"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    result["status"] = "migration-in-progress"
    result["migratedExtensions"] = len(migrated)
    result["indexedExtensions"] = len(index)
    result["hostExecutableSHA256"] = hashlib.sha256((app / "Contents/MacOS/Edith").read_bytes()).hexdigest()
    result["measurement"] = {
        "baselineSourceCommit": baseline["sourceCommit"],
        "architecture": "arm64",
        "signature": "development",
        "appZipMethod": "Regular files only, symlinks excluded, ZIP deflate level 9. Comparison metric, not a shipping installer.",
        "included": ["host executable", "marketplace runtime", "Sparkle updater and its helpers", "application icon", "extension index", "shared Home and Notch layout contract", "code signatures"],
        "outstanding": ["remaining feature migrations", "remaining feature navigation integration", "Home and Notch visual editor and worker card adapters", "Notch extension renderer", "required platform carriers", "shipping release packaging", "final release-host measurements"],
    }
    result["surfaceCustomization"] = {
        "pullRequest": "https://github.com/pulkitxm/edith/pull/1010",
        "reviewedCommit": "f7aa029b299e963262910ac37f6d78172819f1ac",
        "layoutContractVersion": 1,
        "implemented": ["host-owned layouts and profiles", "undo and redo", "availability for every indexed extension", "composite provider filtering", "read-only worker context", "layout retention through worker updates and app restarts"],
        "outstanding": ["visual editor port", "Home card data and action adapters", "Notch renderer and integrations", "synthetic visual verification"],
    }
    return result



def render_markdown(report, index):
    titles = {entry["id"]: entry["title"] for entry in index}
    count = report["migratedExtensions"]
    indexed = report["indexedExtensions"]
    host = report["appWithoutExtensions"]
    baseline = report["baseline"]
    combined = report["appWithMigratedExtensions"]
    totals = report["migratedExtensionPackages"]
    rows = "\n".join(
        f"| {titles[entry['id']]} | {entry['downloadBytes']:,} | {entry['installedBytes']:,} | {entry['releaseMetadataBytes']:,} |"
        for entry in report["packages"]
    )
    return f"""# Lightweight host rebuild measurements

Measured on {report['measuredAtUTC'].split('T')[0]}. The rebuild is in progress and the PR is not ready to merge. {count} of the {indexed} indexed features have been migrated to self-contained workers. These measurements describe the current host foundation, not the final shipping app or all extension packages.

The host contains its executable, marketplace runtime, Sparkle updater including its helpers, application icon, extension metadata, and signatures. It contains zero extension payloads. Feature navigation integration, required platform carriers, the remaining feature migrations, and shipping release packaging still need completion and measurement.

| Measured build | Installed MB | Comparison ZIP MB |
| --- | ---: | ---: |
| Original bundled app | {baseline['installedBytes']/1_000_000:.2f} | {baseline['comparisonZipBytes']/1_000_000:.2f} |
| Superseded partial extraction | 95.70 | 44.94 |
| Current host foundation with updater and shared UI | {host['installedBytes']/1_000_000:.2f} | {host['comparisonZipBytes']/1_000_000:.2f} |
| Host plus all {count} migrated extensions | {combined['installedBytes']/1_000_000:.2f} | {combined['comparisonZipAndPackageBytes']/1_000_000:.2f} |

MB means 1,000,000 bytes. The current host foundation is {report['savedPercent']['installedBytes']:.2f}% smaller on disk than the original bundled app. That percentage will be recalculated after the remaining shipping components are integrated. Comparison ZIPs use deflate level 9 over regular files and exclude symlinks. They are a controlled comparison, not shipping installer sizes.

| Independent release package | ZIP bytes | Installed bytes | Release metadata bytes |
| --- | ---: | ---: | ---: |
{rows}
| All {count} migrated packages | {totals['downloadBytes']:,} | {totals['installedBytes']:,} | {totals['releaseMetadataBytes']:,} |

The {count} ZIPs plus their metadata occupy {totals['releaseAssetBytes']:,} bytes as release assets. A shared signed catalog, checksums, retained older releases, and packages that have not been migrated are outside this subtotal. These are locally built development artifacts; these particular releases have not been published.

Each enabled extension runs in a worker launched from the same Edith executable. Disabling waits for that process to exit, including a forced shutdown when it does not respond. The host also tracks commands launched into their own process groups and stops those groups on disable, crash, or unresponsive shutdown. The lifecycle test confirms that no worker process remains. Removing an extension stops it before deleting its downloaded packages. User preferences remain separate from downloaded code.

Compatible installed extensions survive app updates without downloading them again. Enabled preferences persist, and workers restart when the updated app starts. Extension updates install immutable, verified packages and restart only the affected worker. A failed update attempts to restore the previous working version. Automatic checks run on app startup at most once every eight hours, only when extensions are installed and automatic extension updates are enabled. Users can also check and update manually. Incompatible installed packages are shown as needing a compatible update.

Local `make ci-marketplace-host` verifies worker failure handling, package integrity and signatures, offline catalog behavior, update preferences, restored enabled extensions, and extension behavior. The real-bundle harness opens a native window, installs a newer version while the previous worker is active, replaces that worker, simulates an app restart, disables the extension, checks process exit, and removes its payloads. All {count} migrated extensions pass this flow. Visual review of the completed marketplace and cloud release testing remain outstanding.

Home and Notch customization from [PR #1010](https://github.com/pulkitxm/edith/pull/1010) is part of this rebuild. The shared layout contract, host-owned preferences, profiles, undo/redo, tab order, source filters, and read-only worker context are implemented. The original visual editor, card data/action adapters, and Notch renderer still need porting and visual verification.

A card is active only when its provider is installed, compatible, and running. Downloaded or remembered-enabled extensions do not count as running. Runtime layouts omit inactive cards without changing the saved configuration. Disabled, removed, or temporarily incompatible extensions retain their positions, filters, and profiles for later restoration. The availability planner returns no provider queries for hidden surfaces and hidden cards. A widget cannot implicitly start an extension.

| Customized content | Planned data and action owner |
| --- | --- |
| World clocks | Lightweight host |
| Usage activity, agent usage, rate limits | Usage extension |
| Live agents and permission approvals | Sessions extension |
| Now playing | Music extension |
| Meetings | Calendar extension |
| Code stats | Code Stats extension |
| Focus timer | Attention extension |
| Databases | Database extension |
| Machines | Machines extension |
| GitHub activity | Review extension |
| Quick actions | Running Keep Awake, Lid Awake, Presenter, System, and Mic Mute extensions |
| Desk tools | Running Clipboard, Color Picker, Emoji Picker, and Bifrost extensions |
| Media tools | Running Screen Recorder, Downloads, Virtual Camera, Music, and Studio extensions |
| Individual extension card | Its own extension worker, covering every indexed extension |
| Notch shell, files, browser, camera preview | Downloadable Notch extension |
| Notch Clipboard and Audio tabs | Their own running extension workers |

The Notch browser and camera preview are functions of the Notch package. They do not require Review or Virtual Camera. The Notch renderer will run only while its extension is enabled. External data and actions will cross the worker command boundary as versioned, bounded data; feature models and services stay outside the base app. The existing native runtime tests now also verify that each tested worker reads the same saved Home configuration after replacement and app restart, and that disabling or removing it leaves the layout intact.

Exact byte counts, package checksums, and the host executable checksum are in [the measurement data](extension-host-rebuild-size-report.json). Regenerate both reports after a fresh host build and extension builds:

```sh
make ci-marketplace-host
make ci-extension-workers EXTENSION=--retain-packages
python3 -B scripts/extension-host-size-report.py --baseline local/baseline/size.json --output docs/extension-host-rebuild-size-report.json --markdown-output docs/extension-host-rebuild-size-report.md
```

The baseline JSON records source commit `{report['measurement']['baselineSourceCommit']}` and the original app measurements. The generator verifies each migrated package's ZIP size, SHA-256, expanded bytes, CRC, and current source fingerprint before producing the comparison. Installed sizes exclude filesystem allocation rounding, receipts, caches, user data, and retained versions.
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--app", type=Path, default=Path("local/minimal-host/Edith.app"))
    parser.add_argument("--packages", type=Path, default=Path("dist/extensions"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--markdown-output", type=Path)
    arguments = parser.parse_args()
    fingerprints = json.loads(subprocess.run(["bun", str(Path(__file__).with_name("extension-artifact-fingerprints.mjs"))], check=True, capture_output=True, text=True).stdout)
    report = build_report(json.loads(arguments.baseline.read_text()), arguments.app, arguments.packages, json.loads(Path("Extensions/manifest.json").read_text()), json.loads(Path("Packages/EdithHost/Sources/EdithHostCore/Resources/index.json").read_text()), fingerprints)
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    if arguments.markdown_output:
        index = json.loads(Path("Packages/EdithHost/Sources/EdithHostCore/Resources/index.json").read_text())
        arguments.markdown_output.write_text(render_markdown(report, index))


if __name__ == "__main__":
    main()
