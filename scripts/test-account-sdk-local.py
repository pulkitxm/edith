import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
GROUPS = {
    "Sources/EdithExtensionAccounts": ["ClaudeAccount.swift", "ClaudeAccountStorage.swift", "ClaudeSavedLogin.swift", "OwnedAccountFiles.swift"],
    "Tests/EdithExtensionAccountsTests": ["AccountSupportModelTests.swift", "AccountSupportSavedLoginTests.swift", "AccountSupportStorageTests.swift"],
}
MANIFEST = """// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "AccountContracts",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "EdithExtensionAccounts", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "EdithExtensionAccountsTests", dependencies: ["EdithExtensionAccounts"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
"""


def private_directory(path):
    if path.is_symlink():
        raise ValueError("Local contract directory must not be a symlink")
    path.mkdir(mode=0o700, exist_ok=True)
    info = path.stat()
    if info.st_uid != os.getuid() or not stat.S_ISDIR(info.st_mode):
        raise ValueError("Local contract directory must be owned")
    path.chmod(0o700)
    return path


def verify_source(path, root):
    for parent in [path, *path.parents]:
        if parent == root:
            break
        if parent.is_symlink():
            raise ValueError("Account contract source must not contain symlinks")
    if not path.is_file():
        raise ValueError("Account contract source must be a regular file")


def private_file(path, flags):
    descriptor = os.open(path, flags | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, 0o600)
    info = os.fstat(descriptor)
    if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
        os.close(descriptor)
        raise ValueError("Local contract file must be private and owned")
    return descriptor


def write_private(path, data):
    descriptor = private_file(path, os.O_RDWR)
    with os.fdopen(descriptor, "r+b") as stream:
        if stream.read(len(data) + 1) == data:
            return
        stream.seek(0)
        stream.truncate(0)
        stream.write(data)


def prepare_package(root, package):
    digests = {}
    count = 0
    for group, names in GROUPS.items():
        source = root / "Packages/ExtensionSupport" / group
        if source.is_symlink() or sorted(path.name for path in source.glob("*.swift")) != sorted(names):
            raise ValueError("Account contract source inventory changed")
        destination = package / group
        private_directory(destination.parent)
        private_directory(destination)
        if any(path.name not in names for path in destination.iterdir()):
            raise ValueError("Unexpected local account contract source")
        for name in names:
            path = source / name
            verify_source(path, root)
            data = path.read_bytes()
            write_private(destination / name, data)
            digests[f"{group}/{name}"] = hashlib.sha256(data).hexdigest()
            if group.startswith("Tests/"):
                count += len(re.findall(rb"@Test\b", data))
    write_private(package / "Package.swift", MANIFEST.encode())
    if count == 0:
        raise ValueError("Account contract suite is empty")
    return digests, count


def environment(fixture, modules=None):
    result = {key: os.environ[key] for key in ["PATH", "DEVELOPER_DIR", "LANG", "LC_ALL"] if key in os.environ}
    for name in ["tmp", "cache", "config", "security", "modules", "Data", "ExtensionState"]:
        private_directory(fixture / name)
    private_directory(fixture / "Data/herdr")
    modules = modules or fixture / "modules"
    result.update({
        "HOME": str(fixture), "CFFIXED_USER_HOME": str(fixture), "TMPDIR": str(fixture / "tmp") + "/",
        "XDG_CACHE_HOME": str(fixture / "cache"), "XDG_CONFIG_HOME": str(fixture / "config"),
        "CLANG_MODULE_CACHE_PATH": str(modules), "SWIFTPM_MODULECACHE_OVERRIDE": str(modules),
        "EDITH_EXTENSION_DATA_ROOT": str(fixture / "Data/herdr"), "EDITH_EXTENSION_STATE_ROOT": str(fixture / "ExtensionState"),
        "EDITH_EXTENSION_ID": "herdr", "EDITH_APPLICATION_IDENTIFIER": "com.pulkit.edith.dev.accounts-contracts",
    })
    return result


def test_result(exit_status, output, expected):
    matches = re.findall(rb"Test run with (\d+) tests.*?passed", output)
    passed = int(matches[0]) if len(matches) == 1 else 0
    executed = passed > 0 or re.search(rb"\bTest (?!run\b)[^\r\n]+ started\.", output) is not None
    status = exit_status if exit_status >= 0 else 1
    if status == 0 and (len(matches) != 1 or passed != expected):
        status = 1
    return status, passed, executed


def run():
    allowed = Path(os.environ["EDITH_LOCAL_CI_ROOT"])
    if sys.platform != "darwin" or not allowed.is_absolute() or allowed.resolve(strict=True) != allowed or not ROOT.is_relative_to(allowed):
        raise ValueError("Local account contracts require a macOS checkout inside EDITH_LOCAL_CI_ROOT")
    local = ROOT / "local"
    if local.is_symlink():
        raise ValueError("Local contract storage must not be a symlink")
    local.mkdir(exist_ok=True)
    storage = private_directory(local / "account-contracts")
    with os.fdopen(private_file(storage / "run.lock", os.O_RDWR), "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        package = private_directory(storage / "package")
        build = private_directory(storage / "build")
        modules = private_directory(storage / "modules")
        digests, count = prepare_package(ROOT, package)
        fixture = Path(tempfile.mkdtemp(prefix="fixture-", dir=storage))
        started = time.monotonic()
        try:
            command = ["/usr/sbin/taskpolicy", "-b", "/usr/bin/nice", "-n", "15", "swift", "test", "--package-path", str(package), "--scratch-path", str(build), "--cache-path", str(fixture / "cache"), "--config-path", str(fixture / "config"), "--security-path", str(fixture / "security"), "--filter", "AccountSupport", "--build-system", "swiftbuild", "--no-parallel", "--jobs", "1", "-Xswiftc", "-j1", "-Xswiftc", "-warnings-as-errors", "-Xswiftc", "-module-cache-path", "-Xswiftc", str(modules)]
            child = subprocess.Popen(command, cwd=ROOT, env=environment(fixture, modules), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                output, _ = child.communicate(timeout=360)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                output, _ = child.communicate()
            write_private(storage / "last.log", output)
            sys.stdout.buffer.write(output)
            status, passed, executed = test_result(child.returncode, output, count)
            receipt = {"exit": status, "elapsedSeconds": time.monotonic() - started, "expectedTests": count, "passedTests": passed, "sourceSHA256": digests, "outputSHA256": hashlib.sha256(output).hexdigest(), "applicationExecution": False, "sdkTestsExecuted": executed, "isolatedAccountSDK": True}
            write_private(storage / "receipt.json", (json.dumps(receipt, indent=2) + "\n").encode())
            print(json.dumps(receipt), flush=True)
            return status if status >= 0 else 1
        finally:
            shutil.rmtree(fixture)


if __name__ == "__main__":
    raise SystemExit(run())
