import argparse
import hashlib
import json
import importlib.util
from pathlib import Path
import tempfile
import stat
from size_report_filesystem import TreeSnapshot, digest_file, read_bytes, stable_file
import zipfile


def measure_app(app):
    app = Path(app).absolute()
    if not app.is_dir():
        raise ValueError("The app bundle is missing")
    snapshot = TreeSnapshot(app)
    files = snapshot.files
    with tempfile.TemporaryDirectory(prefix="extension-size-") as directory:
        archive = Path(directory) / "app.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zipped:
            for path in files:
                with stable_file(path) as source, zipped.open(str(path.relative_to(app.parent)), "w") as target:
                    while chunk := source.read(1024 * 1024):
                        target.write(chunk)
        snapshot.verify()
        return {
            "installedBytes": sum(snapshot.entries[path][3] for path in files),
            "comparisonZipBytes": archive.stat().st_size,
        }


def artifact_inventory(directory, expected, additional=None):
    snapshot = TreeSnapshot(directory)
    allowed = {f"{identifier}.{suffix}": category for identifier in expected
        for suffix, category in [("json", "packageMetadata"), ("zip", "packageArchives"),
            ("zip.sha256", "detachedChecksums"), ("ui-carrier-provenance.json", "provenanceReceipts")]}
    for suffix in ["carrier-provenance.json", "synthetic-host-provenance.json"]:
        if "virtualCamera" in expected:
            allowed[f"virtualCamera.{suffix}"] = "provenanceReceipts"
    for name, category in (additional or {}).items():
        if name in allowed or category not in {"signedCatalog", "catalogPointer"}:
            raise ValueError("Invalid additional release artifact")
        allowed[name] = category
    result = []
    files = set(snapshot.files)
    for path in snapshot.entries:
        if path == snapshot.root:
            continue
        name = path.relative_to(snapshot.root).as_posix()
        if name not in allowed or path not in files:
            raise ValueError(f"Unexpected artifact inventory entry: {name}; packages must match every extension")
        result.append({"name": name, "category": allowed[name], "bytes": snapshot.entries[path][3],
                       "sha256": digest_file(path)})
    names = {entry["name"] for entry in result}
    required = {f"{identifier}.{suffix}" for identifier in expected for suffix in ["json", "zip"]}
    if not required.issubset(names) or not set(additional or {}).issubset(names):
        raise ValueError("Measured packages must match every extension in the manifest")
    snapshot.verify()
    return sorted(result, key=lambda entry: entry["name"])


def measure_packages(directory, expected, additional=None):
    directory = Path(directory).absolute()
    artifact_inventory(directory, expected, additional)
    snapshot = TreeSnapshot(directory)
    packages = {}
    for identifier in sorted(expected):
        path = directory / f"{identifier}.json"
        record = json.loads(read_bytes(path))
        if not isinstance(record, dict) or record.get("id") != identifier or not all(
            key in record for key in ["version", "downloadBytes", "installedBytes", "sha256"]
        ):
            raise ValueError("Unsupported package metadata record")
        archive = path.with_suffix(".zip")
        if archive.stat().st_size != record["downloadBytes"] or digest_file(archive) != record["sha256"]:
            raise ValueError(f"Package download size or checksum mismatch: {identifier}")
        with stable_file(archive) as source, zipfile.ZipFile(source) as zipped:
            entries = zipped.infolist()
            names = set()
            for entry in entries:
                parts = Path(entry.filename).parts
                mode = stat.S_IFMT(entry.external_attr >> 16)
                if (entry.filename in names or not parts or parts[0] != identifier
                        or entry.filename.startswith("/") or ".." in parts
                        or "\\" in entry.filename or "\0" in entry.filename
                        or mode not in {0, stat.S_IFREG, stat.S_IFDIR}
                        or (mode == stat.S_IFDIR and not entry.is_dir())):
                    raise ValueError("Package archive contains unsafe, duplicate or unsupported members")
                names.add(entry.filename)
            damaged = zipped.testzip()
            installed = sum(entry.file_size for entry in entries if not entry.is_dir())
        if damaged or installed != record["installedBytes"]:
            raise ValueError(f"Package installed size or CRC mismatch: {identifier}")
        checksum = directory / f"{identifier}.zip.sha256"
        if checksum.exists() and read_bytes(checksum) != f"{record['sha256']}  {identifier}.zip\n".encode():
            raise ValueError("Detached package checksum differs")
        packages[identifier] = {
            key: record[key] for key in ["id", "version", "downloadBytes", "installedBytes", "sha256"]
        }
        packages[identifier]["releaseMetadataBytes"] = path.stat().st_size
    snapshot.verify()
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
    parser.add_argument("--host-build", required=True, type=Path)
    parser.add_argument("--package-source", required=True)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    baseline = json.loads(arguments.baseline.read_text())
    expected = [entry["id"] for entry in json.loads(arguments.manifest.read_text())]
    specification = importlib.util.spec_from_file_location("host_size_validation", Path(__file__).with_name("extension-host-size-report.py"))
    validation = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(validation)
    source = validation.read_source_state(Path.cwd())
    build = json.loads(read_bytes(arguments.host_build))
    validation.validate_final_source(arguments.source_commit, source, build)
    if build.get("hostExecutableSHA256") != digest_file(arguments.app / "Contents/MacOS/Edith"):
        raise ValueError("Host build metadata differs from measured app")
    result = compare(baseline, measure_app(arguments.app), measure_packages(arguments.packages, expected))
    result["releaseArtifactInventory"] = artifact_inventory(arguments.packages, expected)
    result["releaseArtifactBytesByCategory"] = {}
    for asset in result["releaseArtifactInventory"]:
        category = asset["category"]
        result["releaseArtifactBytesByCategory"][category] = result["releaseArtifactBytesByCategory"].get(category, 0) + asset["bytes"]
    validation.validate_final_source(arguments.source_commit, validation.read_source_state(Path.cwd()), build)
    result["measurement"] = {
        "baselineSourceCommit": baseline["sourceCommit"],
        "appSourceCommit": arguments.source_commit,
        "packageSource": arguments.package_source,
        "appSourceCommitVerified": True,
        "hostBuild": {key: build[key] for key in validation.BUILD_FIELDS if key in build},
        "currentPackageSourceFingerprintsVerified": False,
        "architecture": "arm64",
        "appZipMethod": "Regular files only, symlinks excluded, ZIP deflate level 9. Comparison metric, not a shipping installer.",
        "installedMethod": "Logical file bytes including packaged models, excluding filesystem block rounding, receipts, external downloaded models, caches, user data and retained previous versions.",
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
