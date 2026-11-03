import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import resource
import shutil
import signal
import subprocess
import tempfile
import uuid


def execute(arguments, environment=None, timeout=60):
    environment = dict(os.environ) if environment is None else dict(environment)
    environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    result = subprocess.run(arguments, env=environment, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {arguments[0]}\n{result.stderr}")
    return result.stdout.strip()


def plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value))


def signed(path):
    execute(["/usr/bin/codesign", "--force", "--sign", "-", str(path)])


def no_core():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def fixture_environment(destination):
    return {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
        "DEVELOPER_DIR": os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"),
        "EDITH_BACKGROUND_TESTING": "1", "EDITH_USAGE_OFFLINE": "1",
        "EDITH_CRASH_PROOF_ROOT": str(destination), "SWIFT_BACKTRACE": "enable=no",
        "HOME": str(destination / "home"), "CFFIXED_USER_HOME": str(destination / "home"),
        "TMPDIR": str(destination / "temporary"), "LANG": "en_US.UTF-8",
    }


def run_proof(products, destination):
    report = None
    try:
        report = proof(products, destination)
    finally:
        info_path = destination / "CrashRecoveryProof.app/Contents/Info.plist"
        if info_path.exists():
            identifier = plistlib.loads(info_path.read_bytes())["CFBundleIdentifier"]
            if not identifier.startswith("com.pulkit.edith.tests.crash-"):
                raise RuntimeError("Refusing to clean a non-fixture identity")
            for suffix in ["", ".host", ".extensions.crashProbe", ".extensions.healthyProbe"]:
                domain = identifier + suffix
                removed = subprocess.run(
                    ["/usr/bin/defaults", "delete", domain], capture_output=True, timeout=15,
                )
                if removed.returncode:
                    remaining = subprocess.run(
                        ["/usr/bin/defaults", "export", domain, "-"], capture_output=True, timeout=15,
                    )
                    if remaining.returncode == 0 and plistlib.loads(remaining.stdout):
                        raise RuntimeError("Synthetic preference cleanup left stored values")
    print(json.dumps(report, indent=2))


def proof(products, destination):
    repository = Path(__file__).resolve().parent.parent
    sources = repository / "scripts/fixtures/extension-crash"
    identifier = "com.pulkit.edith.tests.crash-" + uuid.uuid4().hex
    app = destination / "CrashRecoveryProof.app"
    contents = app / "Contents"
    executable = contents / "MacOS/CrashRecoveryProof"
    for name in ["MacOS", "Frameworks", "Resources"]:
        (contents / name).mkdir(parents=True, exist_ok=True)
    kit = contents / "Frameworks/libEdithExtensionKit.dylib"
    shutil.copy2(products / "libEdithExtensionKit.dylib", kit)
    objects = []
    for target in ["EdithHostCore", "ExtensionMarketplace", "ZIPFoundation"]:
        objects.extend(sorted((products / f"{target}.build").glob("*.o")))
    if not objects:
        raise RuntimeError("Build the host tests first; compiled host objects are required")
    object_list = destination / "host-objects.txt"
    object_list.write_text("\n".join(str(path) for path in objects) + "\n")
    module_map = products.parent.parent / "checkouts/ZIPFoundation/Sources/CZlib/module.modulemap"
    if not module_map.exists():
        module_map = products.parent.parent.parent / "checkouts/ZIPFoundation/Sources/CZlib/module.modulemap"
    common = [
        "-swift-version", "5", "-I", str(products / "Modules"), "-L", str(products),
        "-lEdithExtensionKit", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
    ]
    if module_map.exists():
        common.extend(["-Xcc", "-fmodule-map-file=" + str(module_map)])
    execute([
        "/usr/bin/xcrun", "swiftc", "-parse-as-library", *common,
        str(sources / "Host.swift"), "-Xlinker", "-filelist", "-Xlinker", str(object_list), "-lz", "-o", str(executable),
    ], timeout=180)
    plist(contents / "Info.plist", {
        "CFBundleIdentifier": identifier, "CFBundleName": "Crash Recovery Proof",
        "CFBundleExecutable": "CrashRecoveryProof", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0.0", "LSUIElement": True,
    })
    entries = [{
        "id": name, "title": name, "symbolName": "square", "category": "desk",
        "background": True, "commands": [], "hotkeys": [], "launchWhen": [], "pages": [],
        "sections": [], "homeCards": [], "notchCards": [], "notchTabs": [],
    } for name in ["crashProbe", "healthyProbe"]]
    (contents / "Resources/index.json").write_text(json.dumps(entries))
    signed(kit)
    signed(app)
    environment = fixture_environment(destination)
    (destination / "home").mkdir()
    (destination / "temporary").mkdir()
    abi = execute([str(executable), "abi", str(destination)], environment)
    state = destination / "support/Edith Tests" / identifier.split(".", 4)[4]
    packages = []
    for name in ["crashProbe", "healthyProbe"]:
        package = {
            "id": name, "version": "1.0.0", "hostABI": abi, "architecture": "arm64",
            "minimumSystemVersion": "14.0.0", "dependencies": [],
            "downloadURL": f"https://github.com/example/fixtures/releases/download/test/{name}.zip",
            "sha256": "a" * 64, "downloadBytes": 1, "installedBytes": 1,
        }
        packages.append(package)
        payload = state / f"Extensions/{name}/{abi}/arm64/1.0.0/{name}"
        bundle = payload / "app.bundle"
        binary = bundle / "Contents/MacOS/Runtime"
        binary.parent.mkdir(parents=True)
        execute([
            "/usr/bin/xcrun", "swiftc", "-emit-library", "-parse-as-library", *common,
            "-module-name", name + "Fixture", str(sources / "Runtime.swift"), "-o", str(binary),
        ], timeout=180)
        plist(bundle / "Contents/Info.plist", {
            "CFBundleIdentifier": f"com.pulkit.edith.extensions.{name}.app",
            "CFBundleExecutable": "Runtime", "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1.0.0", "CFBundleShortVersionString": "1.0.0",
            "EdithHostABI": abi, "EdithRuntimeAPIVersion": 1,
            "FixtureID": name, "FixtureCrashes": name == "crashProbe",
        })
        (payload / "package.json").write_text(json.dumps({key: package[key] for key in [
            "id", "version", "hostABI", "architecture", "minimumSystemVersion", "dependencies",
        ]}))
        signed(bundle)
    (state / "Extensions/installed.json").write_text(json.dumps(packages))
    execute([str(executable), "seed", str(destination)], environment)
    observations = []
    for stage in ["first", "retry"]:
        result = subprocess.run(
            [str(executable), "launch", str(destination)], env=environment,
            capture_output=True, text=True, timeout=30, preexec_fn=no_core,
        )
        (destination / f"{stage}.stderr").write_text(result.stderr)
        if result.returncode != -signal.SIGABRT:
            raise RuntimeError(f"Expected SIGABRT during {stage} start, received {result.returncode}: {result.stderr}")
        persisted = json.loads(execute([str(executable), "inspect", str(destination)], environment))
        if "crashProbe" not in persisted["starting"]:
            raise RuntimeError("The abrupt crash lost its extension startup marker")
        expected_probation = None if stage == "first" else "crashProbe"
        if persisted["probation"] != expected_probation:
            raise RuntimeError("The first retry did not use the expected probation policy")
        observations.append({"stage": stage, "signal": "SIGABRT", **persisted})
    final = json.loads(execute([str(executable), "launch", str(destination)], environment))
    if final["states"] != {"crashProbe": "failed", "healthyProbe": "active"}:
        raise RuntimeError("The repeat crash was not isolated to its extension")
    if final["enabled"] != ["healthyProbe"] or final["starting"] or final["probation"] is not None:
        raise RuntimeError("Crash disable did not persist clean startup state")
    if "turned off" not in final["failureReasons"].get("crashProbe", ""):
        raise RuntimeError("The automatic disable did not explain the crash")
    if json.loads(final["healthyEcho"]) != {"message": "synthetic echo"}:
        raise RuntimeError("The unrelated synthetic extension did not remain usable")
    hashes = {
        name: hashlib.sha256((products / "EdithHostCore.build" / (name + ".swift.o")).read_bytes()).hexdigest()
        for name in ["HostExtensionSessions", "HostWorkerEngine"]
    }
    hashes["ExtensionBundleRuntime"] = hashlib.sha256(
        (products / "ExtensionMarketplace.build/ExtensionBundleRuntime.swift.o").read_bytes()
    ).hexdigest()
    report = {
        "hostABI": abi, "extensionRuntimeAPIVersion": 1, "productionObjectSHA256": hashes,
        "runtimeLibrarySHA256": hashlib.sha256(kit.read_bytes()).hexdigest(),
        "crashes": observations, "recovered": final,
    }
    (destination / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--products", type=Path,
        default=Path(__file__).resolve().parent.parent / "Packages/EdithHost/.build/arm64-apple-macosx/debug",
    )
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    if arguments.output:
        arguments.output.mkdir(parents=True, exist_ok=False)
        run_proof(arguments.products.resolve(), arguments.output.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="edith-crash-recovery-") as temporary:
            run_proof(arguments.products.resolve(), Path(temporary))
