from pathlib import Path
import ctypes
import hashlib
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


spec = importlib.util.spec_from_file_location(
    'hosted_process_watchdog', Path(__file__).parent / 'hosted-host-tests/watchdog.py')
watchdog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watchdog)

TARGETS = {
    'attention': ['ci-extension-attention'],
    'terminal': ['ci-extension-terminal'],
    'timeLapse': ['ci-extension-time-lapse'],
    'studio': ['ci-extension-studio', 'ci-extension-studio-native'],
    'machines': ['ci-extension-machines'],
    'virtualCamera': [
        'ci-extension-camera', 'ci-extension-camera-carrier', 'ci-extension-camera-voice'],
    'feature-models': ['ci-extension-support', 'ci-extension-docs'],
    'database-mutation': ['ci-extension-database-mutation'],
    'database-executor': ['ci-extension-database-executor'],
}
DATABASE_DIAGNOSTICS = {'database-mutation', 'database-executor'}
TEST_DEADLINE = 2400
LOG_BOUND = 16_777_216


class BoundedOwnership(watchdog.OwnedProcesses):
    def __init__(self, leader, uid):
        super().__init__(leader, uid)
        self.errors = []
        self.seals = {}
        self.transitions = []
        self.terminal_children = {}
        self.rejected = {}
        self.failure_observations = []
        self.failure_observation_keys = set()
        self.captured_snapshot_failures = []
        self.captured_snapshot_keys = set()
        value = self.snapshot(leader)
        if value is None or value[4] != leader:
            raise RuntimeError('Owned leader identity unavailable')
        identity = value[:5]
        self.seals[leader] = identity[:3] + identity[4:5]
        self.known[leader] = identity

    def snapshot(self, pid, parent=None, parent_identity=None):
        captured = None

        def capture(clause, result, info):
            nonlocal captured
            complete = result == ctypes.sizeof(info)
            seal = self.seals.get(pid)
            captured = {
                'clause': clause,
                'returnedBytes': result if type(result) is int and -2147483648 <= result <= 2147483647 else None,
                'expectedBytes': ctypes.sizeof(info),
                'status': info.status if complete else None,
                'pidMatches': info.pid == pid if complete else None,
                'birthMatches': (pid, info.seconds, info.microseconds) == seal[:3] if complete and seal else None,
                'groupMatches': info.pgid == seal[3] if complete and seal else None,
                'uidMatches': info.uid == self.uid if complete else None,
                'realUIDMatches': info.ruid == self.uid if complete else None,
                'parentEnumerated': parent is not None,
                'parentIdentityKnown': parent_identity is not None,
                'parentMatches': info.ppid == parent if complete and parent is not None else None,
                'leaderGroupMatches': info.pgid == self.leader if complete else None,
            }

        value = super().snapshot(pid, capture)
        if value is None:
            if captured is not None and captured['clause'] == 'kernel_record_unavailable':
                if self.terminal_child(pid, parent, parent_identity):
                    return None
                recovered = self.recover_snapshot(pid)
                if recovered is not None:
                    return recovered
            if self.sealed_zombie(pid):
                return None
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return None
            self.observe_failure(pid, 'live_identity_unavailable')
            if (captured is not None and pid not in self.captured_snapshot_keys
                    and len(self.captured_snapshot_failures) < 8):
                self.captured_snapshot_keys.add(pid)
                self.captured_snapshot_failures.append(captured)
            raise RuntimeError('Live owned process identity unavailable')
        if pid in self.terminal_children:
            raise RuntimeError('Terminal child identity became live')
        return value

    def terminal_child(self, pid, parent, parent_identity):
        if (type(pid) is not int or pid <= 0 or type(parent) is not int or parent <= 0
                or pid == self.leader or pid in self.seals or pid in self.known
                or parent is None or parent_identity is None
                or parent_identity != self.known.get(parent)
                or parent_identity[0] != parent or parent_identity[4] != self.leader):
            return False
        before_parent = self.recover_snapshot(parent)
        if before_parent is None or before_parent[:5] != parent_identity:
            return False
        records = []
        for _ in range(2):
            info = watchdog.ProcessInfo()
            result = self.library.proc_pidinfo(pid, 3, 1, ctypes.byref(info), ctypes.sizeof(info))
            if (type(result) is not int or result != ctypes.sizeof(info)
                    or info.status != 5 or info.pid != pid
                    or info.uid != self.uid or info.ruid != self.uid
                    or info.ppid != parent or info.pgid != self.leader
                    or info.seconds <= 0 or info.microseconds >= 1_000_000):
                return False
            records.append(bytes(info))
        after_parent = self.recover_snapshot(parent)
        if (records[0] != records[1] or after_parent is None
                or after_parent[:5] != parent_identity):
            return False
        previous = self.terminal_children.get(pid)
        if previous is not None and previous != records[0]:
            raise RuntimeError('Terminal child kernel record changed')
        if previous is None and len(self.terminal_children) + len(self.seals) >= 4096:
            raise RuntimeError('Owned lifetime process bound exceeded')
        self.terminal_children[pid] = records[0]
        return True

    def recover_snapshot(self, pid):
        identity = self.known.get(pid)
        seal = self.seals.get(pid)
        if identity is None or seal is None or identity[:3] + identity[4:5] != seal:
            return None
        snapshots = []
        for _ in range(2):
            info = watchdog.ProcessInfo()
            result = self.library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
            if (type(result) is not int or result != ctypes.sizeof(info)
                    or info.pid != pid or info.status not in (1, 2, 3, 4)
                    or info.uid != self.uid or info.ruid != self.uid
                    or info.seconds <= 0 or info.microseconds >= 1_000_000
                    or (pid, info.seconds, info.microseconds, info.pgid) != seal):
                return None
            path = ctypes.create_string_buffer(4096)
            if self.library.proc_pidpath(pid, path, len(path)) <= 0:
                return None
            snapshots.append((pid, info.seconds, info.microseconds, path.value.decode(),
                              info.pgid, info.ppid))
        return snapshots[1] if snapshots[0] == snapshots[1] else None

    def sealed_zombie(self, pid):
        identity = self.known.get(pid)
        seal = self.seals.get(pid)
        if seal is None or (identity is not None and identity[:3] + identity[4:5] != seal):
            return False
        try:
            info = watchdog.ProcessInfo()
            result = self.library.proc_pidinfo(pid, 3, 1, ctypes.byref(info), ctypes.sizeof(info))
        except OSError:
            return False
        return (type(result) is int and result == ctypes.sizeof(info)
                and info.status == 5 and info.pid == pid
                and info.uid == self.uid and info.ruid == self.uid
                and (pid, info.seconds, info.microseconds, info.pgid) == seal)

    def observe_failure(self, pid, kind, current=None):
        key = (pid, kind)
        if len(self.failure_observations) >= 8 or key in self.failure_observation_keys:
            return
        self.failure_observation_keys.add(key)
        seal = self.seals.get(pid)
        known = pid in self.known and seal is not None
        row = {
            'kind': kind, 'knownSeal': known,
            'originalBirthMatches': current[:3] == seal[:3] if current and known else None,
            'originalGroupMatches': current[4] == seal[3] if current and known else None,
            'returnedBytes': None, 'expectedBytes': ctypes.sizeof(watchdog.ProcessInfo),
            'status': None, 'pidMatches': None, 'birthMatches': None,
            'groupMatches': None, 'uidMatches': None, 'realUIDMatches': None,
            'probeFailed': False,
        }
        try:
            info = watchdog.ProcessInfo()
            result = self.library.proc_pidinfo(pid, 3, 1, ctypes.byref(info), ctypes.sizeof(info))
            if type(result) is not int or not -2147483648 <= result <= 2147483647:
                raise ValueError('Invalid diagnostic byte count')
            row['returnedBytes'] = result
            if result == ctypes.sizeof(info):
                row.update(status=info.status, pidMatches=info.pid == pid,
                           birthMatches=(pid, info.seconds, info.microseconds) == seal[:3] if known else None,
                           groupMatches=info.pgid == seal[3] if known else None,
                           uidMatches=info.uid == self.uid, realUIDMatches=info.ruid == self.uid)
        except Exception:
            row['probeFailed'] = True
        self.failure_observations.append(row)

    def reject(self, pid, message):
        if message not in self.errors and len(self.errors) < 64:
            self.errors.append(message)
        if pid in self.known:
            self.rejected[pid] = self.known[pid]

    def refresh(self):
        pending = [(self.leader, None)] + [(pid, None) for pid in self.known]
        visited = set()
        active = {}
        while pending:
            pid, parent = pending.pop()
            if pid in visited:
                continue
            visited.add(pid)
            try:
                value = self.snapshot(pid, parent, active.get(parent))
                if value is None:
                    self.known.pop(pid, None)
                    continue
                identity = value[:5]
                seal = identity[:3] + identity[4:5]
                previous = self.seals.get(pid)
                if previous is not None and previous != seal:
                    self.observe_failure(pid, 'birth_or_group_changed', identity)
                    raise RuntimeError('Owned process birth or group changed')
                if previous is None:
                    if pid == self.leader:
                        if identity[4] != self.leader:
                            raise RuntimeError('Owned leader group changed')
                    elif parent not in active or value[5] != parent:
                        raise RuntimeError('Owned descendant parent changed')
                    else:
                        parent_snapshot = self.snapshot(parent)
                        if parent_snapshot is None or parent_snapshot[:5] != active[parent]:
                            raise RuntimeError('Owned parent identity changed before admission')
                    if len(self.seals) + len(self.terminal_children) >= 4096:
                        raise RuntimeError('Owned lifetime process bound exceeded')
                    self.seals[pid] = seal
                prior = self.known.get(pid)
                if prior is not None and prior[3] != identity[3]:
                    if len(self.transitions) >= 1024:
                        raise RuntimeError('Owned executable transition bound exceeded')
                    self.transitions.append({'previous': prior, 'current': identity})
                if len(active) >= 64:
                    raise RuntimeError('Owned concurrent descendant bound exceeded')
                self.known[pid] = identity
                active[pid] = identity
                children = (ctypes.c_int * 64)()
                count = self.library.proc_listchildpids(pid, children, ctypes.sizeof(children))
                if count < 0 or count >= len(children):
                    raise RuntimeError('Invalid owned child enumeration')
                pending.extend((children[index], pid) for index in range(count))
            except (OSError, RuntimeError) as error:
                self.reject(pid, str(error))
        return list(active.values())

    def conflicts(self):
        return list(self.rejected.values())

    def verified(self, identity):
        try:
            current = self.identity(identity[0])
            if current is not None and current != identity:
                self.reject(identity[0], 'Owned identity changed before signal')
            return current == identity
        except (OSError, RuntimeError) as error:
            self.reject(identity[0], str(error))
            return False

    def terminate(self, value):
        for identity in self.refresh():
            if self.verified(identity):
                try:
                    os.kill(identity[0], value)
                except ProcessLookupError:
                    pass


def retire_unobserved(process):
    for value in (signal.SIGTERM, signal.SIGKILL):
        try:
            if os.getpgid(process.pid) == process.pid:
                os.killpg(process.pid, value)
        except ProcessLookupError:
            pass
    process.wait(timeout=5)


def admit(environment, source):
    expected = environment.get('EXPECTED_SOURCE_SHA', '')
    owner = environment.get('NATIVE_TEST_OWNER', '')
    required = {
        'GITHUB_ACTIONS': 'true', 'RUNNER_OS': 'macOS',
        'RUNNER_ENVIRONMENT': 'github-hosted', 'GITHUB_EVENT_NAME': 'workflow_dispatch',
        'GITHUB_REPOSITORY': 'pulkitxm/edith', 'GITHUB_REPOSITORY_ID': '1289153439',
        'EDITH_HOSTED_NATIVE_OWNER_TESTS': '1',
        'EDITH_HOSTED_RELEASE': 'false', 'EDITH_HOSTED_REBUILD': '',
    }
    if (any(environment.get(key) != value for key, value in required.items())
            or environment.get('GITHUB_ACTOR_ID') not in ('65671483', '320458784')
            or environment.get('GITHUB_REF') not in (
                'refs/heads/feat/extension-marketplace', 'refs/heads/main')
            or re.fullmatch('[0-9a-f]{40}', expected) is None
            or expected != environment.get('GITHUB_SHA') or expected != source
            or owner not in TARGETS):
        raise ValueError('Original native tests require exact-source disposable hosted admission')
    return owner


def original_command(owner, definitions):
    targets = TARGETS[owner]
    if owner != 'feature-models':
        original_owner = 'database' if owner in DATABASE_DIAGNOSTICS else owner
        original_targets = ['ci-extension-database'] if owner in DATABASE_DIAGNOSTICS else targets
        selected = [definition for definition in definitions if definition.get('id') == original_owner]
        if len(selected) != 1 or selected[0].get('testTargets') != original_targets:
            raise ValueError('Original owner test target contract changed')
    return ['make', *targets]


def database_completed(text, owner):
    if owner not in DATABASE_DIAGNOSTICS:
        raise ValueError('Unknown database diagnostic selection')
    duration = r'[0-9]+(?:\.[0-9]+)?'
    start = re.search(r'^◇ Suite DatabaseExecutorTests started\.$', text, re.MULTILINE)
    if start is None:
        return False
    end = re.search(
        r'^✔ Suite DatabaseExecutorTests passed after ' + duration + r' seconds?\.$',
        text[start.end():], re.MULTILINE)
    if end is None:
        return False
    suite = text[start.end():start.end() + end.start()]
    if re.search(r'^[✘✗]|^.*(?:Issue recorded|failed after)', text, re.MULTILINE):
        return False
    summary = re.search(
        r'^✔ Test run with ([1-9][0-9]*) tests? in [1-9][0-9]* suites? passed after '
        + duration + r' seconds?\.$', text, re.MULTILINE)
    if summary is None or summary.start() <= start.end() + end.end():
        return False
    if owner == 'database-mutation':
        name = 'mutationPreviewNormalizesWithoutExecuting'
        starts = re.findall(r'^◇ Test ([A-Za-z0-9_]+)\(\) started\.$', suite, re.MULTILINE)
        passes = re.findall(
            r'^✔ Test ([A-Za-z0-9_]+)\(\) passed after ' + duration + r' seconds?\.$',
            suite, re.MULTILINE)
        return starts == [name] and passes == [name] and int(summary.group(1)) == 1
    return bool(re.search(r'^◇ Test .+ started\.$', suite, re.MULTILINE)
                and re.search(r'^✔ Test .+ passed after ' + duration + r' seconds?\.$',
                              suite, re.MULTILINE))


def testing_process(path):
    name = Path(path).name
    return name in ('swiftpm-testing', 'swiftpm-testing-helper') or name.endswith('PackageTests')


def retire(process, ownership, clock, sleep):
    natural_survivors = ownership.refresh()
    conflicts = ownership.conflicts()
    if natural_survivors:
        ownership.terminate(signal.SIGTERM)
        deadline = clock() + 5
        while ownership.refresh() and clock() < deadline:
            sleep(0.1)
        ownership.terminate(signal.SIGKILL)
    reaped = True
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        ownership.terminate(signal.SIGKILL)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            reaped = False
    deadline = clock() + 5
    while ownership.refresh() and clock() < deadline:
        sleep(0.1)
    return {
        'naturalSurvivorCount': len(natural_survivors), 'reaped': reaped,
        'remainingOwnedProcesses': len(ownership.refresh()),
        'unverifiedOwnedProcesses': len(conflicts),
        'ownershipErrors': getattr(ownership, 'errors', []),
    }


def run_original(arguments, root, environment, output, deadline=TEST_DEADLINE,
                 process_factory=subprocess.Popen, ownership_factory=BoundedOwnership,
                 clock=time.monotonic, sleep=time.sleep, sample=subprocess.run, selection=None):
    if selection is not None and selection not in DATABASE_DIAGNOSTICS:
        raise ValueError('Unknown database diagnostic selection')
    started = clock()
    wall_start = time.time()
    log_path = output / 'tests.log'
    observed = set()
    timed_out = False
    overflow = False
    failure = None
    with log_path.open('wb') as log, (output / 'processes.jsonl').open('w') as timeline:
        process = process_factory(
            arguments, cwd=root, env=environment, stdout=log,
            stderr=subprocess.STDOUT, start_new_session=True)
        try:
            ownership = ownership_factory(process.pid, os.getuid())
        except Exception:
            retire_unobserved(process)
            raise
        next_heartbeat = started
        try:
            while True:
                current = ownership.refresh()
                newly_seen = [identity for identity in current if identity not in observed]
                observed.update(current)
                now = clock()
                if newly_seen or now >= next_heartbeat:
                    timeline.write(json.dumps({
                        'elapsedSeconds': round(now - started, 3),
                        'newOwnedProcesses': newly_seen, 'activeOwnedProcesses': current,
                        'logBytes': log_path.stat().st_size,
                        'parentExitCode': process.poll(),
                    }) + '\n')
                    timeline.flush()
                    next_heartbeat = now + 30
                if process.poll() is not None:
                    break
                overflow = log_path.stat().st_size > LOG_BOUND
                timed_out = now - started >= deadline
                if timed_out or overflow:
                    ownership.terminate(signal.SIGSTOP)
                    for index, identity in enumerate(
                            [item for item in current if testing_process(item[3])][:2]):
                        if ownership.identity(identity[0]) == identity:
                            try:
                                sample(
                                    ['/usr/bin/sample', str(identity[0]), '3', '-file',
                                     str(output / f'owned-test-{index}.sample')],
                                    timeout=10, check=False, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
                            except (OSError, subprocess.TimeoutExpired) as error:
                                timeline.write(json.dumps({'sampleFailure': str(error)}) + '\n')
                                timeline.flush()
                    break
                sleep(0.5)
        except Exception as error:
            failure = str(error)
        finally:
            cleanup = retire(process, ownership, clock, sleep)
    if log_path.stat().st_size > LOG_BOUND:
        with log_path.open('r+b') as bounded:
            bounded.truncate(LOG_BOUND)
    for path in output.glob('*.sample'):
        if path.stat().st_size > 8_388_608:
            path.write_text('Owned test process sample exceeded its diagnostic bound.\n')
    text = log_path.read_text(errors='replace')
    completed = bool(re.search(
        r'Test run with [1-9][0-9]* tests? (?:in [1-9][0-9]* suites? )?passed|Executed [1-9][0-9]* tests?, with 0 failures',
        text))
    if selection is not None:
        completed = completed and database_completed(text, selection)
    code = 124 if timed_out else 1 if overflow or failure else process.returncode
    observed_testing = any(testing_process(item[3]) for item in observed)
    passed = (code == 0 and completed and observed_testing and cleanup['naturalSurvivorCount'] == 0
              and cleanup['reaped'] and cleanup['remainingOwnedProcesses'] == 0
              and cleanup['unverifiedOwnedProcesses'] == 0 and not cleanup['ownershipErrors'])
    return {
        'argv': arguments, 'exitCode': code, 'passed': passed, 'timedOut': timed_out,
        'logBoundExceeded': overflow, 'failure': failure,
        'testsCompleted': completed, 'durationSeconds': round(clock() - started, 3),
        'observedTestingProcess': observed_testing,
        'ownedExecutableTransitions': getattr(ownership, 'transitions', []),
        'ownershipFailureObservations': getattr(ownership, 'failure_observations', []),
        'capturedSnapshotFailures': getattr(ownership, 'captured_snapshot_failures', []),
        'knownOwnedProcesses': list(observed), 'cleanup': cleanup,
        'logSHA256': hashlib.sha256(log_path.read_bytes()).hexdigest(),
        'ownedCrashReports': watchdog.owned_crash_reports(
            Path.home() / 'Library/Logs/DiagnosticReports', output, list(observed), wall_start),
    }


def interrupted(signum, frame):
    raise InterruptedError(f'Hosted native test runner received signal {signum}')


def main():
    if sys.argv[1:]:
        raise ValueError('Unexpected native owner test arguments')
    root = Path(__file__).resolve().parent.parent
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    owner = admit(os.environ, source)
    manifest = root / 'Extensions/manifest.json'
    command = original_command(owner, json.loads(manifest.read_text()))
    output = root / 'local/hosted-native-owner-tests'
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    outcome = {
        'schema': 1, 'owner': owner, 'sourceCommit': source,
        'manifestSHA256': hashlib.sha256(manifest.read_bytes()).hexdigest(),
        'commandDeadlineSeconds': TEST_DEADLINE,
        'passed': False,
    }
    fixture = Path(tempfile.mkdtemp(prefix='edith-owner-tests-', dir=os.environ['RUNNER_TEMP']))
    home = fixture / 'home'
    home.mkdir(mode=0o700)
    environment = {key: value for key, value in os.environ.items() if not key.startswith('EDITH_')}
    environment.update({
        'HOME': str(home), 'CFFIXED_USER_HOME': str(home), 'TMPDIR': str(fixture) + '/',
        'EXTENSION_SWIFT_JOBS': '1', 'EDITH_MAKE_GATE': 'skip',
        'NSUnbufferedIO': 'YES', 'NO_COLOR': '1',
    })
    previous_handlers = {value: signal.signal(value, interrupted) for value in (signal.SIGTERM, signal.SIGINT)}
    try:
        outcome['toolchain'] = {
            name: subprocess.check_output(arguments, text=True, timeout=30).strip()
            for name, arguments in [
                ('swift', ['swift', '--version']), ('xcode', ['xcodebuild', '-version']),
                ('sdk', ['xcrun', '--sdk', 'macosx', '--show-sdk-version']),
            ]
        }
        environment['DEVELOPER_DIR'] = subprocess.check_output(
            ['xcode-select', '-p'], text=True, timeout=30).strip()
        outcome['result'] = run_original(
            command, root, environment, output,
            selection=owner if owner in DATABASE_DIAGNOSTICS else None)
        outcome['passed'] = outcome['result']['passed']
    except Exception as error:
        outcome['failure'] = str(error)
    finally:
        (output / 'outcome.json').write_text(json.dumps(outcome, indent=2) + '\n')
        for value, handler in previous_handlers.items():
            signal.signal(value, handler)
        shutil.rmtree(fixture)
    print(json.dumps(outcome))
    return 0 if outcome['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
