import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import zipfile


def measure_app(app):
    if not app.is_dir():
        raise ValueError("The app bundle is missing")
    files = sorted(path for path in app.rglob("*") if path.is_file() and not path.is_symlink())
    with tempfile.TemporaryDirectory(prefix="extension-size-") as directory:
        archive = Path(directory) / "app.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zipped:
            for path in files:
                zipped.write(path, path.relative_to(app.parent))
        return {
            "installedBytes": sum(path.stat().st_size for path in files),
            "comparisonZipBytes": archive.stat().st_size,
        }


def measure_packages(directory, expected):
    packages = {}
    for path in sorted(directory.rglob("*.json")):
        record = json.loads(path.read_text())
        if not isinstance(record, dict) or not all(
            key in record for key in ["id", "version", "downloadBytes", "installedBytes", "sha256"]
        ):
            continue
        identifier = record["id"]
        if identifier in packages:
            raise ValueError(f"Duplicate package: {identifier}")
        archive = path.with_suffix(".zip")
        data = archive.read_bytes()
        if len(data) != record["downloadBytes"] or hashlib.sha256(data).hexdigest() != record["sha256"]:
            raise ValueError(f"Package download size or checksum mismatch: {identifier}")
        with zipfile.ZipFile(archive) as zipped:
            damaged = zipped.testzip()
            installed = sum(entry.file_size for entry in zipped.infolist() if not entry.is_dir())
        if damaged or installed != record["installedBytes"]:
            raise ValueError(f"Package installed size or CRC mismatch: {identifier}")
        packages[identifier] = {
            key: record[key] for key in ["id", "version", "downloadBytes", "installedBytes", "sha256"]
        }
        packages[identifier]["releaseMetadataBytes"] = path.stat().st_size
    if set(packages) != set(expected):
        raise ValueError("Measured packages must match every extension in the manifest")
    return [packages[identifier] for identifier in sorted(packages)]


def compare(baseline, current, packages):
    old = {
        "installedBytes": baseline["installedBytes"],
        "comparisonZipBytes": baseline["zipBytes"],
    }
    saved = {key: old[key] - current[key] for key in old}
    totals = {
        "downloadBytes": sum(package["downloadBytes"] for package in packages),
        "installedBytes": sum(package["installedBytes"] for package in packages),
        "releaseMetadataBytes": sum(package.get("releaseMetadataBytes", 0) for package in packages),
    }
    totals["releaseAssetBytes"] = totals["downloadBytes"] + totals["releaseMetadataBytes"]
    return {
        "baseline": old,
        "appWithoutExtensions": current,
        "savedBytes": saved,
        "savedPercent": {key: round(saved[key] * 100 / old[key], 2) if old[key] else None for key in old},
        "packages": packages,
        "allExtensionPackages": totals,
        "appWithAllExtensions": {
            "installedBytes": current["installedBytes"] + totals["installedBytes"],
            "comparisonZipAndPackageBytes": current["comparisonZipBytes"] + totals["downloadBytes"],
        },
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--packages", required=True, type=Path)
    parser.add_argument("--manifest", type=Path, default=Path("Extensions/manifest.json"))
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--package-source", required=True)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    baseline = json.loads(arguments.baseline.read_text())
    expected = [entry["id"] for entry in json.loads(arguments.manifest.read_text())]
    result = compare(baseline, measure_app(arguments.app), measure_packages(arguments.packages, expected))
    result["measurement"] = {
        "baselineSourceCommit": baseline["sourceCommit"],
        "appSourceCommit": arguments.source_commit,
        "packageSource": arguments.package_source,
        "architecture": "arm64",
        "appZipMethod": "Regular files only, symlinks excluded, ZIP deflate level 9. Comparison metric, not a shipping installer.",
        "installedMethod": "Logical file bytes, excluding filesystem block rounding, receipts, caches, models, user data and retained previous versions.",
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
