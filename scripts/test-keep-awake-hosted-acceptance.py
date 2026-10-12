from pathlib import Path
import hashlib
import importlib.util
import json
import os
import re
import signal
import subprocess
import sys
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def native_proof(value, source):
    require(value.get('schema') == 1 and value.get('sourceCommit') == source
            and value.get('owner') == 'keepAwake', 'Native result identity mismatch')
    for field in ['originalCheckboxActivated', 'productionRuntimeInvoked',
                  'realIOKitAssertionVerified', 'shutdownAssertionReleased',
                  'requestedPreferencePreserved']:
        require(value.get(field) is True, 'Missing native result: ' + field)
    require(value.get('transitions') == [True, False, True], 'Original toggle transitions incomplete')
    require(value.get('syntheticPlatformAdapter') is False, 'Real assertion was replaced by a fixture')
    require(value.get('workerProcessLifecycleVerified') is False, 'Native UI test overclaims worker coverage')


def lifecycle_proof(value):
    require(value.get('id') == 'keepAwake', 'Foreign worker lifecycle result')
    for field in ['downloadedBundle', 'headlessLifecycle', 'engineLifecycleValidated',
                  'updateWithoutAppRestart', 'restoreAfterAppUpdate', 'freshHostSessionRestored',
                  'pendingDisableRecoveryValidated', 'removedPayloads', 'isolatedSupportTypes',
                  'surfaceLayoutRestored', 'surfaceDataValidated']:
        require(value.get(field) is True, 'Missing worker lifecycle result: ' + field)
    require(value.get('disabledProcesses') == 0, 'Worker cleanup incomplete')
    require(value.get('nativeWindow') is False and value.get('managedNativeViewValidated') is False,
            'Fixture lifecycle overclaims native presentation coverage')


def native_failure_diagnostics(value, log_path):
    if value['passed']:
        return
    fields = ['exitCode', 'timedOut', 'logBoundExceeded', 'failure',
              'testsCompleted', 'observedTestingProcess']
    metadata = {field: value[field] for field in fields}
    if metadata['failure'] is not None:
        metadata['failure'] = str(metadata['failure'])[:1024]
    cleanup = value['cleanup']
    metadata['cleanup'] = {field: cleanup[field] for field in
                           ['naturalSurvivorCount', 'reaped', 'remainingOwnedProcesses',
                            'unverifiedOwnedProcesses']}
    metadata['cleanup']['ownershipErrorCount'] = len(cleanup['ownershipErrors'])
    print(json.dumps({'nativeFailure': metadata}), flush=True)
    try:
        with log_path.open('rb') as log:
            log.seek(0, os.SEEK_END)
            log.seek(max(0, log.tell() - 16384))
            tail = log.read(16384).decode('utf-8', errors='replace')
        tail = tail.encode('utf-8')[-16384:].decode('utf-8', errors='ignore')
    except OSError:
        tail = ''
    print(json.dumps({'nativeLogTail': tail}), flush=True)


def private_directory(path, private=False):
    require(path.resolve() == path and not path.is_symlink(), 'Output path traverses a symlink')
    attributes = path.stat()
    require(path.is_dir() and attributes.st_uid == os.getuid()
            and attributes.st_mode & 0o022 == 0, 'Output directory is not exclusively owned')
    if private:
        require(attributes.st_mode & 0o777 == 0o700, 'Acceptance directory is not private')


def main():
    require(not sys.argv[1:], 'Unexpected acceptance arguments')
    environment = os.environ
    required = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted',
                'RUNNER_OS': 'macOS', 'GITHUB_REPOSITORY': 'pulkitxm/edith',
                'GITHUB_REPOSITORY_ID': '1289153439'}
    require(all(environment.get(key) == value for key, value in required.items()),
            'Keep Awake acceptance requires a disposable hosted Mac')
    require(environment.get('GITHUB_ACTOR_ID') in ['65671483', '320458784'], 'Unreviewed actor')
    require(environment.get('GITHUB_REF') in ['refs/heads/main', 'refs/heads/feat/extension-marketplace'],
            'Unreviewed source ref')
    source = environment.get('EXPECTED_SOURCE_SHA', '')
    require(re.fullmatch('[0-9a-f]{40}', source) is not None
            and source == environment.get('GITHUB_SHA'), 'Source identity mismatch')
    root = Path(__file__).resolve().parents[1]
    require(subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip() == source,
            'Checkout source mismatch')
    require(not subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'],
                                        cwd=root, text=True).strip(), 'Tracked source is dirty')
    paths = ['Makefile', 'Extensions/manifest.json', 'Extensions/keepAwake/Package.swift',
             'scripts/test-keep-awake-hosted-acceptance.py', 'scripts/test-extension-workers.mjs',
             'scripts/hosted-native-owner-tests.py', 'scripts/hosted-host-tests/watchdog.py']
    paths += [str(path.relative_to(root)) for path in (root / 'Extensions/keepAwake').rglob('*.swift')
              if '.build' not in path.parts]
    pins = {path: digest(root / path) for path in sorted(set(paths))}
    harness = Path(environment.get('EXTENSION_LIFECYCLE_HARNESS',
                                  'Packages/EdithHost/.build/debug/HostLifecycleHarness'))
    if not harness.is_absolute():
        harness = root / harness
    require(harness.resolve() == harness and harness.is_file() and not harness.is_symlink()
            and os.access(harness, os.X_OK), 'Missing canonical worker lifecycle harness')
    require(harness.is_relative_to(root), 'Lifecycle harness must belong to this checkout')
    harness_pin = digest(harness)
    require((root / 'local/minimal-host/Edith.app').is_dir(), 'Frozen host is missing')
    local = root / 'local'
    local.mkdir(exist_ok=True)
    private_directory(local)
    output = root / 'local/keep-awake-acceptance'
    output.mkdir(mode=0o700, exist_ok=True)
    private_directory(output, private=True)
    work = Path(tempfile.mkdtemp(prefix='run-', dir=output)).resolve()
    work.chmod(0o700)
    for name in ['home', 'tmp', 'config', 'cache', 'data', 'native', 'worker']:
        (work / name).mkdir(mode=0o700)
    child_environment = {key: value for key, value in environment.items()
                         if key in {'PATH', 'DEVELOPER_DIR', 'SDKROOT', 'LANG', 'LC_ALL',
                                    'RUNNER_ENVIRONMENT', 'RUNNER_OS'}
                         or key.startswith('GITHUB_') and key != 'GITHUB_TOKEN'}
    child_environment.update(HOME=str(work / 'home'), CFFIXED_USER_HOME=str(work / 'home'),
                             TMPDIR=str(work / 'tmp') + '/', XDG_CONFIG_HOME=str(work / 'config'),
                             XDG_CACHE_HOME=str(work / 'cache'), XDG_DATA_HOME=str(work / 'data'),
                             EXPECTED_SOURCE_SHA=source, PYTHONDONTWRITEBYTECODE='1',
                             EXTENSION_LIFECYCLE_HARNESS=str(harness), EXTENSION_SWIFT_JOBS='1')
    native_receipt = work / 'native.json'
    child_environment.update(EDITH_KEEP_AWAKE_HOSTED_ACCEPTANCE='1',
                             KEEP_AWAKE_NATIVE_RECEIPT=str(native_receipt))
    spec = importlib.util.spec_from_file_location('keep_awake_owned_runner',
                                                 root / 'scripts/hosted-native-owner-tests.py')
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    os.environ.update({key: child_environment[key] for key in ['HOME', 'CFFIXED_USER_HOME', 'TMPDIR']})
    for value in [signal.SIGINT, signal.SIGTERM]:
        signal.signal(value, runner.interrupted)
    result = {'schema': 1, 'owner': 'keepAwake', 'sourceCommit': source,
              'sourcePins': pins, 'lifecycleHarnessSHA256': harness_pin,
              'native': None, 'worker': None, 'passed': False,
              'publicPackageAcceptanceVerified': False, 'allExtensionsQualified': False}
    try:
        native = runner.run_original(['make', 'ci-extension-keep-awake'], root,
                                     child_environment, work / 'native', deadline=900)
        result['native'] = native
        native_failure_diagnostics(native, work / 'native/tests.log')
        require(native['passed'], 'Original Keep Awake native suite did not complete cleanly')
        native_result = json.loads(native_receipt.read_text())
        native_proof(native_result, source)
        result['nativeControl'] = native_result
        result['nativeReceiptSHA256'] = digest(native_receipt)
        worker = runner.run_original(
            ['bun', 'scripts/test-extension-workers.mjs', 'keepAwake', '--retain-packages'],
            root, child_environment, work / 'worker', deadline=900)
        result['worker'] = worker
        cleanup = worker['cleanup']
        require(worker['exitCode'] == 0 and not worker['timedOut']
                and not worker['logBoundExceeded'] and worker['failure'] is None
                and cleanup['naturalSurvivorCount'] == 0 and cleanup['reaped']
                and cleanup['remainingOwnedProcesses'] == 0
                and cleanup['unverifiedOwnedProcesses'] == 0 and not cleanup['ownershipErrors'],
                'Keep Awake worker lifecycle did not complete cleanly')
        records = []
        for line in (work / 'worker/tests.log').read_text().splitlines():
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if isinstance(value, dict) and value.get('id') == 'keepAwake':
                records.append(value)
        require(len(records) == 1, 'Worker lifecycle result missing or repeated')
        lifecycle_proof(records[0])
        result['fixtureWorkerLifecycle'] = records[0]
        result['sourceUnchanged'] = all(digest(root / path) == pin for path, pin in pins.items())
        require(result['sourceUnchanged'], 'Acceptance source changed during execution')
        require(digest(harness) == harness_pin, 'Lifecycle harness changed during execution')
        result['passed'] = True
    except Exception as error:
        result['failure'] = str(error)
        raise
    finally:
        receipt = work / 'receipt.json'
        receipt.write_text(json.dumps(result, indent=2) + '\n')
        receipt.chmod(0o600)
        print(json.dumps({'receipt': str(receipt), 'passed': result['passed']}), flush=True)


if __name__ == '__main__':
    main()
