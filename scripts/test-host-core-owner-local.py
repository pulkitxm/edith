import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'Packages/EdithHost/Tests/EdithHostCoreTests/HostCoreOwnerTests.swift'
PROGRAM = 'Packages/EdithHost/Tests/EdithHostCoreTests/Fixtures/core-owner.py'
SUITES = ['HostCoreOwnerTests', 'HostCoreOwnerFrameTests', 'HostCoreOwnerDiagnosticTests']


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


isolation = module('test-account-sdk-local')
native = isolation.OWNERSHIP
driver_api = native.DRIVERS


def environment(fixture, modules):
    value = isolation.environment(fixture, modules)
    for key in list(value):
        if key.startswith('EDITH_'):
            del value[key]
    isolation.private_directory(fixture / 'data')
    isolation.private_directory(fixture / 'runtime')
    isolation.private_directory(fixture / 'Data/usage')
    value.update({
        'EDITH_BACKGROUND_TESTING': '1', 'EDITH_TEST_NATIVE_CAPTURE': '0',
        'XDG_DATA_HOME': str(fixture / 'data'), 'XDG_STATE_HOME': str(fixture / 'runtime'),
        'EDITH_EXTENSION_DATA_ROOT': str(fixture / 'Data/usage'),
        'EDITH_EXTENSION_STATE_ROOT': str(fixture / 'ExtensionState'),
        'EDITH_APPLICATION_IDENTIFIER': 'com.pulkit.edith.dev.core-owner-contracts',
        'EDITH_SHARED_DEFAULTS_SUITE': 'edith.core-owner.local.' + fixture.name,
        'PYTHONDONTWRITEBYTECODE': '1', 'NO_COLOR': '1', 'NSUnbufferedIO': 'YES',
    })
    return value


def arguments(driver, fixture, package):
    return [
        str(driver.validate()), '--package-path', str(package),
        '--build-system', 'native', '--no-parallel', '--jobs', '1',
        '-Xswiftc', '-j1', '-Xswiftc', '-plugin-path', '-Xswiftc',
        str(driver.developer / 'Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins'),
        '--cache-path', str(fixture / 'cache'), '--config-path', str(fixture / 'config'),
        '--security-path', str(fixture / 'security'), '--filter', 'HostCoreOwner',
    ]


def completion(text, methods):
    starts = re.findall(r'^◇ Test (\w+)\(', text, re.MULTILINE)
    passes = re.findall(r'^✔ Test (\w+)\(', text, re.MULTILINE)
    suites = re.findall(r'^✔ Suite (\w+) passed after ', text, re.MULTILINE)
    rows = re.findall(r'argument iteration → ([0-7]) to liveChildWithoutProtocolRequestsRetiresAndJoins', text)
    return (sorted(starts) == sorted(methods) == sorted(passes)
            and sorted(suites) == sorted(SUITES)
            and sorted(rows) == [str(index) for index in range(8)]
            and len(re.findall(r'Test run with 13 tests in 3 suites passed', text)) == 1)


def execute(command, child_environment, output):
    previous = dict(os.environ)
    try:
        os.environ.clear()
        os.environ.update(child_environment)
        return native.run_selected_original(command, ROOT, child_environment, output)
    finally:
        os.environ.clear()
        os.environ.update(previous)


def run():
    if sys.argv[1:]:
        raise ValueError('Unexpected local owner fixture arguments')
    allowed = Path(os.environ['EDITH_LOCAL_CI_ROOT'])
    if (sys.platform != 'darwin' or not allowed.is_absolute()
            or allowed.resolve(strict=True) != allowed or not ROOT.is_relative_to(allowed)):
        raise ValueError('Owner fixtures require a checkout inside EDITH_LOCAL_CI_ROOT')
    package = ROOT / 'Packages/EdithHost'
    build = package / '.build'
    if build.is_symlink() or (build.exists() and build.resolve(strict=True) != build):
        raise ValueError('Owner build cache must remain inside its package')
    storage = isolation.private_directory(isolation.private_directory(ROOT / 'local') / 'host-core-owner')
    with os.fdopen(isolation.private_file(storage / 'run.lock', os.O_RDWR), 'r+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        paths = [SOURCE, PROGRAM, 'Packages/EdithHost/Package.swift']
        pins = {}
        for name in paths:
            path = ROOT / name
            isolation.verify_source(path, ROOT)
            pins[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        source = (ROOT / SOURCE).read_text()
        methods = re.findall(r'@Test(?:\([^\n]*\))?\s*(?:@MainActor\s+)?func\s+(\w+)', source)
        if len(methods) != 13 or re.findall(r'@Suite struct (\w+)', source) != SUITES:
            raise ValueError('Owner fixture source selection changed')
        fixture = Path(tempfile.mkdtemp(prefix='fixture-', dir=storage))
        output = isolation.private_directory(fixture / 'output')
        modules = isolation.private_directory(storage / 'modules')
        result = None
        qualified = False
        try:
            driver = driver_api.SelectedSwiftDriver(os.environ['DEVELOPER_DIR'], entry='swift-test')
            result = execute(arguments(driver, fixture, package), environment(fixture, modules), output)
            driver.validate()
            for name, digest in pins.items():
                if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
                    raise ValueError('Owner fixture source changed during execution')
            exact = completion((output / 'tests.log').read_text(errors='replace'), methods)
            result.update({'exactOwnerSelection': exact, 'sourceSHA256': pins,
                           'expectedMethods': 13, 'expectedSuites': 3,
                           'expectedExpandedInvocations': 20})
            result['passed'] = result['passed'] and exact
            isolation.write_private(storage / 'last-receipt.json', (json.dumps(result, indent=2) + '\n').encode())
            sys.stdout.buffer.write((output / 'tests.log').read_bytes())
            print(json.dumps(result), flush=True)
            qualified = result['passed']
            return 0 if result['passed'] else 1
        finally:
            if qualified:
                shutil.rmtree(fixture)


if __name__ == '__main__':
    sys.exit(run())
