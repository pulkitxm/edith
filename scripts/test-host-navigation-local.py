import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('local_isolation', ROOT / 'scripts/test-account-sdk-local.py')
isolation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(isolation)
SOURCES = {
    'Packages/ExtensionSupport/Sources/EdithExtensionSupport/AppStorageKeys.swift': 'Sources/EdithExtensionSupport/AppStorageKeys.swift',
    'Packages/EdithHost/Sources/EdithHost/HostNavigationCatalog.swift': 'Sources/EdithHost/HostNavigationCatalog.swift',
    'Packages/EdithHost/Tests/EdithHostUITests/HostOptionalNavigationTests.swift': 'Tests/HostNavigationTests/HostOptionalNavigationTests.swift',
}
MANIFEST = """// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "HostNavigationContracts",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "EdithExtensionSupport"),
        .target(name: "EdithHost", dependencies: ["EdithExtensionSupport"]),
        .testTarget(name: "HostNavigationTests", dependencies: ["EdithHost"])
    ]
)
"""


def prepare_package(package):
    digests = {}
    count = 0
    for source, destination in SOURCES.items():
        path = ROOT / source
        isolation.verify_source(path, ROOT)
        data = path.read_bytes()
        output = package / destination
        output.parent.mkdir(mode=0o700, parents=True)
        isolation.write_private(output, data)
        digests[source] = hashlib.sha256(data).hexdigest()
        if destination.startswith('Tests/'):
            count += len(re.findall(rb'@Test\b', data))
    if count == 0:
        raise ValueError('Local host navigation suite is empty')
    isolation.write_private(package / 'Package.swift', MANIFEST.encode())
    return digests, count


def retire_child(child):
    if child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    child.communicate()


def run():
    allowed = Path(os.environ['EDITH_LOCAL_CI_ROOT'])
    if sys.platform != 'darwin' or not allowed.is_absolute() or allowed.resolve(strict=True) != allowed or not ROOT.is_relative_to(allowed):
        raise ValueError('Local host contracts require a macOS checkout inside EDITH_LOCAL_CI_ROOT')
    local = ROOT / 'local'
    isolation.private_directory(local)
    storage = isolation.private_directory(local / 'host-navigation-contracts')
    fixture = Path(tempfile.mkdtemp(prefix='fixture-', dir=storage))
    started = time.monotonic()
    child = None
    try:
        package = isolation.private_directory(fixture / 'package')
        digests, count = prepare_package(package)
        environment = isolation.environment(fixture)
        command = ['/usr/sbin/taskpolicy', '-b', '/usr/bin/nice', '-n', '15', 'swift', 'test', '--package-path', str(package), '--scratch-path', str(fixture / 'build'), '--cache-path', str(fixture / 'cache'), '--config-path', str(fixture / 'config'), '--security-path', str(fixture / 'security'), '--filter', 'HostOptionalNavigationTests', '--build-system', 'swiftbuild', '--no-parallel', '--jobs', '1', '-Xswiftc', '-j1', '-Xswiftc', '-warnings-as-errors', '-Xswiftc', '-module-cache-path', '-Xswiftc', str(fixture / 'modules')]
        child = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            output, _ = child.communicate(timeout=360)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            output, _ = child.communicate()
        isolation.write_private(storage / 'last.log', output)
        sys.stdout.buffer.write(output)
        status, passed, executed = isolation.test_result(child.returncode, output, count)
        for source, digest in digests.items():
            isolation.verify_source(ROOT / source, ROOT)
            if hashlib.sha256((ROOT / source).read_bytes()).hexdigest() != digest:
                status = 1
        receipt = {'exit': status, 'elapsedSeconds': time.monotonic() - started, 'expectedTests': count, 'passedTests': passed, 'sourceSHA256': digests, 'outputSHA256': hashlib.sha256(output).hexdigest(), 'applicationExecution': False, 'navigationTestsExecuted': executed, 'nativeProductUIExecuted': False}
        isolation.write_private(storage / 'receipt.json', (json.dumps(receipt, indent=2) + '\n').encode())
        print(json.dumps(receipt), flush=True)
        return status
    finally:
        if child is not None:
            retire_child(child)
        shutil.rmtree(fixture)


if __name__ == '__main__':
    raise SystemExit(run())
