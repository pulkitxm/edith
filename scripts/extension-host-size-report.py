import argparse
import hashlib
import importlib.util
import json
from pathlib import Path


def build_report(baseline, app, packages, definitions, index):
    migrated = [entry["id"] for entry in definitions if entry.get("contractVersion") == 1]
    specification = importlib.util.spec_from_file_location("size_measurements", Path(__file__).with_name("extension-size-report.py"))
    measurements = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(measurements)
    measured = measurements.measure_app(app)
    result = measurements.compare(baseline, measured, measurements.measure_packages(packages, migrated))
    result["migratedExtensionPackages"] = result.pop("allExtensionPackages")
    result["appWithMigratedExtensions"] = result.pop("appWithAllExtensions")
    result["status"] = "migration-in-progress"
    result["migratedExtensions"] = len(migrated)
    result["indexedExtensions"] = len(index)
    result["hostExecutableSHA256"] = hashlib.sha256((app / "Contents/MacOS/Edith").read_bytes()).hexdigest()
    result["measurement"] = {
        "architecture": "arm64",
        "signature": "development",
        "appZipMethod": "Regular files only, symlinks excluded, ZIP deflate level 9. Comparison metric, not a shipping installer.",
        "included": ["host executable", "marketplace runtime", "Sparkle updater and its helpers", "application icon", "extension index", "code signatures"],
        "outstanding": ["remaining feature migrations", "remaining feature navigation integration", "required platform carriers", "shipping release packaging", "final release-host measurements"],
    }
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--app", type=Path, default=Path("local/minimal-host/Edith.app"))
    parser.add_argument("--packages", type=Path, default=Path("dist/extensions"))
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    report = build_report(json.loads(arguments.baseline.read_text()), arguments.app, arguments.packages, json.loads(Path("Extensions/manifest.json").read_text()), json.loads(Path("Packages/EdithHost/Sources/EdithHostCore/Resources/index.json").read_text()))
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
