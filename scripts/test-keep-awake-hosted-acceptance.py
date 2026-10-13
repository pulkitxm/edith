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

    ownership_kinds = {
        'Live owned process identity unavailable': 'live_identity_unavailable',
        'Owned process birth or group changed': 'birth_or_group_changed',
        'Owned leader group changed': 'leader_group_changed',
        'Owned descendant parent changed': 'descendant_parent_changed',
        'Owned parent identity changed before admission': 'parent_identity_changed',
        'Owned lifetime process bound exceeded': 'lifetime_process_bound_exceeded',
        'Owned executable transition bound exceeded': 'executable_transition_bound_exceeded',
        'Owned concurrent descendant bound exceeded': 'concurrent_descendant_bound_exceeded',
        'Invalid owned child enumeration': 'child_enumeration_invalid',
        'Owned identity changed before signal': 'identity_changed_before_signal',
    }
    kinds = sorted({ownership_kinds[error] for error in cleanup['ownershipErrors']
                    if isinstance(error, str) and error in ownership_kinds})
    if kinds:
        print(json.dumps({'nativeOwnershipFailureKinds': kinds}), flush=True)

    observations = []
    boolean_fields = ['originalBirthMatches', 'originalGroupMatches', 'pidMatches',
                      'birthMatches', 'groupMatches', 'uidMatches', 'realUIDMatches']
    fields = {'kind', 'knownSeal', 'returnedBytes', 'expectedBytes', 'status', 'probeFailed',
              *boolean_fields}
    self_group_fields = {'knownChild', 'groupIsOwnPID', 'originalParentRetained',
                         'currentPathMatchesRetained', 'twoChildRecordsMatch',
                         'parentBeforeMatches', 'parentAfterMatches',
                         'parentRecordsStable', 'transitionAdmitted'}
    recovery_stages = {'retained_identity', 'first_kernel', 'first_path',
                       'second_kernel', 'second_path', 'snapshot_fields'}
    terminal_booleans = {
        'terminalParentPIDMatches', 'terminalParentGroupMatchesLeader',
        'terminalParentGroupMatchesSeal', 'terminalParentGroupIsSelf',
        'terminalChildRecordComplete', 'terminalChildIsZombie',
        'terminalChildGroupMatchesParent', 'terminalChildGroupMatchesLeader',
        'terminalChildParentMatches', 'terminalRawRecordsStable',
    }
    terminal_fields = {'terminalRefusalReason', 'terminalChildRole',
                       'terminalParentIdentityKnown', *terminal_booleans}
    terminal_reasons = {'parent_admission', 'parent_before', 'first_child_record',
                        'second_child_record', 'child_records_changed', 'parent_after', 'unknown'}
    proof_stages = recovery_stages | {'not_attempted', 'unknown'}
    optional_groups = [self_group_fields, {'recoveryFailureStage'},
                       {'recoveryProofStage'}, terminal_fields]
    optional_fields = set().union(*optional_groups)
    candidates = value.get('ownershipFailureObservations', [])
    for row in candidates[:8] if isinstance(candidates, list) else []:
        if not isinstance(row, dict) or not fields.issubset(row):
            continue
        extra = set(row) - fields
        if (extra - optional_fields
                or any(extra & group and not group.issubset(extra) for group in optional_groups)):
            continue
        extended = self_group_fields.issubset(extra)
        recovery = 'recoveryFailureStage' in extra
        proof = 'recoveryProofStage' in extra
        terminal = terminal_fields.issubset(extra)
        if (row['kind'] not in ['live_identity_unavailable', 'birth_or_group_changed']
                or row['kind'] not in kinds
                or (recovery or proof or terminal) and row['kind'] != 'live_identity_unavailable'
                or extended and row['kind'] != 'birth_or_group_changed'
                and not (row['kind'] == 'live_identity_unavailable' and proof)
                or extended and any(type(row[field]) is not bool for field in self_group_fields)
                or recovery and (type(row['recoveryFailureStage']) is not str
                                 or row['recoveryFailureStage'] not in recovery_stages)
                or proof and (type(row['recoveryProofStage']) is not str
                              or row['recoveryProofStage'] not in proof_stages)
                or terminal and (type(row['terminalRefusalReason']) is not str
                                 or row['terminalRefusalReason'] not in terminal_reasons
                                 or type(row['terminalChildRole']) is not str
                                 or row['terminalChildRole'] not in {'leader', 'known', 'unsealed'}
                                 or type(row['terminalParentIdentityKnown']) is not bool
                                 or any(row[field] is not None and type(row[field]) is not bool
                                        for field in terminal_booleans))
                or type(row['knownSeal']) is not bool or type(row['probeFailed']) is not bool
                or any(row[field] is not None and type(row[field]) is not bool
                       for field in boolean_fields)
                or type(row['expectedBytes']) is not int or not 1 <= row['expectedBytes'] <= 4096
                or row['returnedBytes'] is not None and (type(row['returnedBytes']) is not int
                    or not -2147483648 <= row['returnedBytes'] <= 2147483647)
                or row['status'] is not None and (type(row['status']) is not int
                    or not 0 <= row['status'] <= 4294967295)):
            continue
        observations.append(row)
    if observations:
        print(json.dumps({'nativeOwnershipFailureObservations': observations}), flush=True)

    captured = []
    optional_booleans = ['pidMatches', 'birthMatches', 'groupMatches', 'uidMatches',
                         'realUIDMatches', 'parentMatches', 'leaderGroupMatches']
    fields = {'clause', 'returnedBytes', 'expectedBytes', 'status', 'parentEnumerated',
              'parentIdentityKnown', *optional_booleans}
    clauses = {'kernel_record_unavailable', 'effective_uid_mismatch', 'real_uid_mismatch',
               'executable_path_unavailable', 'invalid_process_group'}
    candidates = value.get('capturedSnapshotFailures', [])
    for row in candidates[:8] if isinstance(candidates, list) else []:
        if (not isinstance(row, dict) or set(row) != fields
                or type(row['clause']) is not str or row['clause'] not in clauses
                or 'live_identity_unavailable' not in kinds
                or type(row['parentEnumerated']) is not bool
                or type(row['parentIdentityKnown']) is not bool
                or any(row[field] is not None and type(row[field]) is not bool
                       for field in optional_booleans)
                or type(row['expectedBytes']) is not int or not 1 <= row['expectedBytes'] <= 4096
                or row['returnedBytes'] is not None and (type(row['returnedBytes']) is not int
                    or not -2147483648 <= row['returnedBytes'] <= 2147483647)
                or row['status'] is not None and (type(row['status']) is not int
                    or not 0 <= row['status'] <= 4294967295)):
            continue
        captured.append(row)
    if captured:
        print(json.dumps({'nativeOwnershipCapturedSnapshotFailures': captured}), flush=True)



def worker_failure_diagnostics(value, log_path=None):
    cleanup = value['cleanup']
    clean = (value['exitCode'] == 0 and not value['timedOut']
             and not value['logBoundExceeded'] and value['failure'] is None
             and cleanup['naturalSurvivorCount'] == 0 and cleanup['reaped']
             and cleanup['remainingOwnedProcesses'] == 0
             and cleanup['unverifiedOwnedProcesses'] == 0 and not cleanup['ownershipErrors'])
    if clean:
        return
    boolean = lambda item: item if type(item) is bool else None
    integer = lambda item: item if type(item) is int and -2147483648 <= item <= 2147483647 else None
    kinds = {
        'Live owned process identity unavailable': 'live_identity_unavailable',
        'Owned process birth or group changed': 'birth_or_group_changed',
        'Owned leader group changed': 'leader_group_changed',
        'Owned descendant parent changed': 'descendant_parent_changed',
        'Owned parent identity changed before admission': 'parent_identity_changed',
        'Owned lifetime process bound exceeded': 'lifetime_process_bound_exceeded',
        'Owned executable transition bound exceeded': 'executable_transition_bound_exceeded',
        'Owned concurrent descendant bound exceeded': 'concurrent_descendant_bound_exceeded',
        'Invalid owned child enumeration': 'child_enumeration_invalid',
        'Owned identity changed before signal': 'identity_changed_before_signal',
    }
    errors = cleanup['ownershipErrors']
    harness_signal = None
    harness_stage = None
    signals = {'SIGABRT', 'SIGBUS', 'SIGILL', 'SIGKILL', 'SIGSEGV', 'SIGTERM', 'SIGTRAP'}
    stages = {
        'fixtureOwnerBegin', 'fixtureOwnerComplete', 'fixtureCopyBegin', 'fixtureCopyComplete',
        'fixtureSignBegin', 'fixtureSignComplete', 'hostIdentityBegin', 'hostIdentityComplete',
        'fixtureHomeBegin', 'fixtureHomeComplete', 'packageStoreBegin', 'packageStoreComplete',
        'ownerDefaultsBegin', 'ownerDefaultsComplete', 'peerEndpointBegin', 'peerEndpointComplete',
        'sessionsBegin', 'sessionsComplete', 'surfacesBegin', 'surfacesComplete',
        'packageInstallBegin', 'packageInstallComplete',
    }
    if log_path is not None:
        try:
            with log_path.open('rb') as log:
                log.seek(0, os.SEEK_END)
                log.seek(max(0, log.tell() - 16384))
                tail = log.read(16384).decode('utf-8', errors='replace')
            for line in tail.splitlines():
                if len(line.encode('utf-8')) > 1024:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(row, dict) or set(row) != {'lifecycleHarnessFailure'}:
                    continue
                failure = row['lifecycleHarnessFailure']
                if (not isinstance(failure, dict)
                        or set(failure) != {'signal', 'pid', 'source', 'stage'}
                        or type(failure['signal']) is not str or failure['signal'] not in signals
                        or failure['stage'] is not None
                           and (type(failure['stage']) is not str or failure['stage'] not in stages)
                        or type(failure['pid']) is not int or not 1 < failure['pid'] <= 2147483647
                        or failure['source'] is not None
                           and (type(failure['source']) is not str
                                or re.fullmatch('[0-9a-f]{40}', failure['source']) is None)):
                    continue
                harness_signal = failure['signal']
                harness_stage = failure['stage']
        except OSError:
            pass
    metadata = {
        'exitCode': integer(value['exitCode']),
        'timedOut': boolean(value['timedOut']),
        'logBoundExceeded': boolean(value['logBoundExceeded']),
        'failurePresent': value['failure'] is not None,
        'harnessSignal': harness_signal,
        'harnessStage': harness_stage,
        'testsCompleted': boolean(value.get('testsCompleted')),
        'observedTestingProcess': boolean(value.get('observedTestingProcess')),
        'cleanup': {
            **{field: integer(cleanup[field]) for field in
               ['naturalSurvivorCount', 'remainingOwnedProcesses', 'unverifiedOwnedProcesses']},
            'reaped': boolean(cleanup['reaped']),
            'ownershipErrorCount': len(errors),
        },
        'ownershipFailureKinds': sorted({kinds[error] for error in errors
                                         if isinstance(error, str) and error in kinds}),
    }
    print(json.dumps({'workerFailure': metadata}, separators=(',', ':')), flush=True)


def private_directory(path, private=False):
    require(path.resolve() == path and not path.is_symlink(), 'Output path traverses a symlink')
    attributes = path.stat()
    require(path.is_dir() and attributes.st_uid == os.getuid()
            and attributes.st_mode & 0o022 == 0, 'Output directory is not exclusively owned')
    if private:
        require(attributes.st_mode & 0o777 == 0o700, 'Acceptance directory is not private')


def admit_source(environment, root):
    required = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted',
                'RUNNER_OS': 'macOS', 'GITHUB_REPOSITORY': 'pulkitxm/edith',
                'GITHUB_REPOSITORY_ID': '1289153439'}
    require(all(environment.get(key) == value for key, value in required.items()),
            'Keep Awake acceptance requires a disposable hosted Mac')
    require(environment.get('GITHUB_ACTOR_ID') in ['65671483', '320458784'], 'Unreviewed actor')
    preview = (environment.get('GITHUB_REF')
               == 'refs/heads/fix/keep-awake-accessibility-action'
               and environment.get('GITHUB_EVENT_NAME') == 'workflow_dispatch'
               and environment.get('EXTENSION_PUBLISH') == 'false')
    require(environment.get('GITHUB_REF') in ['refs/heads/main', 'refs/heads/feat/extension-marketplace']
            or preview, 'Unreviewed source ref')
    source = environment.get('EXPECTED_SOURCE_SHA', '')
    require(re.fullmatch('[0-9a-f]{40}', source) is not None
            and source == environment.get('GITHUB_SHA'), 'Source identity mismatch')
    require(subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip() == source,
            'Checkout source mismatch')
    require(not subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'],
                                        cwd=root, text=True).strip(), 'Tracked source is dirty')
    return source


def main():
    require(not sys.argv[1:], 'Unexpected acceptance arguments')
    environment = os.environ
    root = Path(__file__).resolve().parents[1]
    source = admit_source(environment, root)
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
        worker_failure_diagnostics(worker, work / 'worker/tests.log')
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
