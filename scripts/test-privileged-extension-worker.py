import argparse
import importlib.util
import json
import os
import plistlib
import shutil
import stat
import subprocess
import tempfile
import uuid
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Packages/EdithHost/Tests/EdithHostCoreTests/Fixtures"
CARRIER = PurePosixPath("lidAwake/ExtensionCarrier.app")
WORKER = CARRIER / "Contents/Extensions/ExtensionWorker.appex"
ROLE = WORKER / "Contents/Resources/Payload/lidAwake/privileged.bundle"


def checked(command, timeout=30):
    return subprocess.run(command, check=True, capture_output=True, timeout=timeout)


def info(bundle):
    with (bundle / "Contents/Info.plist").open("rb") as stream:
        value = plistlib.load(stream)
    if not isinstance(value, dict):
        raise ValueError("Invalid bundle metadata")
    return value


def regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Expected a regular executable or metadata file")
    return path


def signed(bundle):
    checked(["codesign", "--verify", "--deep", "--strict", str(bundle)])


def unsigned_digest(path):
    spec = importlib.util.spec_from_file_location("privileged_code_report", ROOT / "scripts/extension-host-size-report.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.unsigned_executable_digest(regular(path))


def extract_package(archive, destination):
    with zipfile.ZipFile(archive) as package:
        entries = package.infolist()
        if not entries or len(entries) > 10_000 or sum(entry.file_size for entry in entries) > 256 * 1024 * 1024:
            raise ValueError("Package exceeds fixture bounds")
        names = set()
        for entry in entries:
            path = PurePosixPath(entry.filename)
            mode = entry.external_attr >> 16
            if (path.is_absolute() or ".." in path.parts or "\\" in entry.filename
                or not path.parts or path.parts[0] != "lidAwake" or len(entry.filename.encode()) > 4096
                or path.as_posix() in names or stat.S_ISLNK(mode)
                or (stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR))):
                raise ValueError("Unsafe package entry")
            names.add(path.as_posix())
        package.extractall(destination)
    if (destination / "lidAwake/privileged.bundle").exists():
        raise ValueError("Flat ABI1 payloads are rejected")


def verify_payload(app, extracted):
    signed(app)
    app_info = info(app)
    if app_info.get("CFBundleExecutable") != "Edith" or not isinstance(app_info.get("CFBundleIdentifier"), str) or not app_info["CFBundleIdentifier"]:
        raise ValueError("Expected the current same-executable host")
    original = unsigned_digest(app / "Contents/MacOS/Edith")
    carrier = extracted.joinpath(*CARRIER.parts)
    worker = extracted.joinpath(*WORKER.parts)
    role = extracted.joinpath(*ROLE.parts)
    for bundle in (carrier, worker):
        signed(bundle)
        value = info(bundle)
        if value.get("CFBundleExecutable") != "Edith" or value.get("EdithExtensionID") != "lidAwake" or value.get("EdithHostABI") != "edith-host-2":
            raise ValueError("Invalid contained worker metadata")
        if unsigned_digest(bundle / "Contents/MacOS/Edith") != original:
            raise ValueError("Contained executable differs from the supplied host")
    signed(role)
    value = info(role)
    if value.get("CFBundleIdentifier") != "com.pulkit.edith.extensions.lidAwake.privileged" or value.get("CFBundleExecutable") != "Runtime" or value.get("EdithHostABI") != "edith-host-2":
        raise ValueError("Expected the shipping privileged role")
    regular(role / "Contents/MacOS/Runtime")
    return original


def prepare_synthetic(app, destination, expected_digest):
    cloned = destination / "Host.app"
    shutil.copytree(app, cloned, symlinks=True)
    value = info(cloned)
    value["CFBundleIdentifier"] = "com.pulkit.edith.dev.lifetime-" + str(uuid.uuid4())
    with (cloned / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(value, stream)
    checked(["codesign", "--force", "--deep", "--sign", "-", str(cloned)])
    signed(cloned)
    if unsigned_digest(cloned / "Contents/MacOS/Edith") != expected_digest:
        raise ValueError("Synthetic clone changed executable code")
    callback = destination / "Callback.bundle"
    binary = callback / "Contents/MacOS/Runtime"
    binary.parent.mkdir(parents=True)
    with (callback / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": "com.pulkit.edith.tests.lifetime-runtime", "CFBundleExecutable": "Runtime", "CFBundlePackageType": "BNDL"}, stream)
    source = regular(FIXTURES / "privileged-lifecycle-runtime.swift")
    checked(["xcrun", "swiftc", "-emit-library", "-parse-as-library", "-swift-version", "5", "-target", "arm64-apple-macos14.0", str(source), "-o", str(binary)], timeout=60)
    checked(["codesign", "--force", "--sign", "-", str(callback)])
    signed(callback)
    return cloned, callback


def result_from_lifetime(value):
    required = ["confirmedQuitExited", "forcedStopRestoredCallback", "eofRestoredCallback", "staleWorkerRejected", "forcedReasonRetentionRejected", "parentExitWithOpenInputRestoredCallback"]
    if not isinstance(value, dict) or type(value.get("signedWorkerCases")) is not int or value["signedWorkerCases"] != 6 or any(value.get(key) is not True for key in required) or any(type(value.get(key)) is not int or value[key] != 0 for key in ("operatingSystemActions", "visibleWindows")):
        raise ValueError("Synthetic privileged lifecycle proof is incomplete")
    return {"signedPayload": True, "sameExecutable": True, "isolatedPrivilegedWorkers": True,
        "restoredBeforeExit": value["forcedStopRestoredCallback"],
        "connectionLossExited": value["eofRestoredCallback"] and value["parentExitWithOpenInputRestoredCallback"],
        "disabledProcesses": 0, "productionSystemEffects": value["operatingSystemActions"],
        "lifecycleScope": "synthetic-restoration-callback", "shippingPrivilegedRoleExecuted": False,
        "syntheticLifecycle": value}


def run(app, archive):
    if os.geteuid() == 0:
        raise ValueError("Run the synthetic privileged fixture without root privileges")
    app = Path(app).absolute()
    if app.is_symlink() or app.resolve() != app:
        raise ValueError("Host path must be canonical")
    with tempfile.TemporaryDirectory(prefix="privileged-extension-fixture-") as directory:
        root = Path(directory).resolve()
        extracted = root / "shipping"
        extracted.mkdir()
        extract_package(archive, extracted)
        digest = verify_payload(app, extracted)
        cloned, callback = prepare_synthetic(app, root, digest)
        response = checked(["/usr/bin/python3", "-B", str(FIXTURES / "privileged-lifecycle.py"), "--app", str(cloned), "--bundle", str(callback)], timeout=45)
        if len(response.stdout) > 65536:
            raise ValueError("Synthetic lifecycle response exceeds bounds")
        return result_from_lifetime(json.loads(response.stdout))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", default="local/minimal-host/Edith.app")
    parser.add_argument("--package", default="dist/extensions/lidAwake.zip")
    args = parser.parse_args()
    print(json.dumps(run(args.app, args.package)))


if __name__ == "__main__":
    main()
