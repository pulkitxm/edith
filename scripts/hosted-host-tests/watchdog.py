import ctypes
import datetime
import json
import os
import re
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path


class ProcessInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid',
        'rgid', 'svuid', 'svgid', 'rfu1')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in (
        'nfiles', 'pgid', 'pjobc', 'e_tdev', 'e_tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('seconds', ctypes.c_uint64),
                ('microseconds', ctypes.c_uint64)]


class OwnedProcesses:
    def __init__(self, leader, uid):
        self.library = ctypes.CDLL('/usr/lib/libproc.dylib')
        self.leader = leader
        self.uid = uid
        self.known = {}
        self.parents = {}

    def snapshot(self, pid):
        info = ProcessInfo()
        result = self.library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
        if result != ctypes.sizeof(info) or info.uid != self.uid or info.ruid != self.uid:
            return None
        path = ctypes.create_string_buffer(4096)
        if self.library.proc_pidpath(pid, path, len(path)) <= 0:
            return None
        if info.pgid <= 0:
            return None
        return (pid, info.seconds, info.microseconds, path.value.decode(), info.pgid, info.ppid)

    def identity(self, pid):
        snapshot = self.snapshot(pid)
        return None if snapshot is None else snapshot[:5]

    def refresh(self):
        pending = [(self.leader, None)] + [(pid, None) for pid in self.known]
        visited = set()
        while pending:
            pid, parent = pending.pop()
            if pid in visited:
                continue
            visited.add(pid)
            if len(visited) > 64:
                raise RuntimeError('Owned descendant bound exceeded')
            snapshot = self.snapshot(pid)
            if snapshot is None:
                continue
            identity = snapshot[:5]
            previous = self.known.get(pid)
            if previous is None:
                if pid == self.leader:
                    if identity[4] != self.leader:
                        continue
                elif parent not in self.known or snapshot[5] != parent:
                    continue
            if previous is not None and previous != identity:
                continue
            self.known[pid] = identity
            if pid not in self.parents:
                self.parents[pid] = parent
            children = (ctypes.c_int * 64)()
            count = self.library.proc_listchildpids(pid, children, ctypes.sizeof(children))
            if count < 0 or count >= len(children):
                raise RuntimeError('Invalid owned child enumeration')
            pending.extend((children[index], pid) for index in range(count))
        return [value for value in self.known.values() if self.identity(value[0]) == value]

    def conflicts(self):
        return [previous for pid, previous in self.known.items()
                if (current := self.identity(pid)) is not None
                and current[:3] == previous[:3] and current != previous]

    def terminate(self, value):
        for identity in self.refresh():
            if self.identity(identity[0]) == identity:
                os.kill(identity[0], value)


def admit(environment, source):
    required = {'GITHUB_ACTIONS': 'true', 'RUNNER_OS': 'macOS',
                'RUNNER_ENVIRONMENT': 'github-hosted', 'EDITH_HOSTED_HOST_TESTS': '1',
                'GITHUB_REPOSITORY': 'pulkitxm/edith', 'EDITH_HOSTED_RELEASE': 'false',
                'EDITH_HOSTED_REBUILD': ''}
    allowed_refs = {'refs/heads/feat/hosted-host-test-diagnostics',
                    'refs/heads/feat/hosted-journey-registration',
                    'refs/heads/feat/extension-marketplace', 'refs/heads/main'}
    if (any(environment.get(key) != value for key, value in required.items())
            or environment.get('GITHUB_REF') not in allowed_refs
            or environment.get('GITHUB_ACTOR_ID') not in {'65671483', '320458784'}):
        raise ValueError('Disposable hosted test admission failed')
    expected = environment.get('EXPECTED_SOURCE_SHA', '')
    if not re.fullmatch('[a-f0-9]{40}', expected) or expected != source:
        raise ValueError('Reviewed source mismatch')


def command(batch, developer, helper=None, executable=None):
    common = ['--package-path', 'Packages/EdithHost', '--build-system', 'native',
              '--jobs', '1', '-Xswiftc', '-plugin-path', '-Xswiftc',
              str(Path(developer) / 'Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins')]
    if batch == 'build':
        return [str(Path(developer) / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'),
                'build', '--build-tests', *common]
    filters = {'transport': '^EdithHostCoreTests\\.HostCLITransportTests',
               'core': '^(EdithHostCoreTests|HostLifecycleHarnessTests)\\.',
               'ui': '^EdithHostUITests\\.'}
    selected = filters[batch]
    if helper is None or executable is None:
        raise ValueError('Validated selected toolchain helper and test executable required')
    image = Path(executable)
    if (not image.is_absolute() or '..' in image.parts
            or image.parts[-4:] != ('EdithHostPackageTests.xctest', 'Contents', 'MacOS', 'EdithHostPackageTests')):
        raise ValueError('Native test executable must be inside its owning bundle')
    return [str(helper), '--test-bundle-path', str(image), 'test', '--skip-build',
            '--no-parallel', *common, '--filter', selected, str(image),
            '--testing-library', 'swift-testing']


def canonical_path(path, directory=False):
    path = Path(path)
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise ValueError('Noncanonical diagnostic executable or bundle path')
    metadata = path.lstat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(metadata.st_mode) or metadata.st_uid not in {0, os.getuid()}:
        raise ValueError('Unexpected diagnostic path ownership or type')
    if metadata.st_mode & 0o022:
        raise ValueError('Writable diagnostic path')
    if not directory and not os.access(path, os.X_OK):
        raise ValueError('Diagnostic executable is not executable')
    return path


def runtime_contract(developer, bin_directory, package, environment, bundle_name='EdithHostPackageTests'):
    if bundle_name not in {'EdithHostPackageTests', 'DatabaseEnginePackageTests'}:
        raise ValueError('Unexpected diagnostic test bundle')
    developer = canonical_path(developer, directory=True)
    if developer.parts[-2:] != ('Contents', 'Developer'):
        raise ValueError('Unexpected selected developer layout')
    toolchain = canonical_path(developer / 'Toolchains/XcodeDefault.xctoolchain', directory=True)
    helper = canonical_path(toolchain / 'usr/libexec/swift/pm/swiftpm-testing-helper')
    package = canonical_path(package, directory=True)
    build_root = canonical_path(package / '.build', directory=True)
    bin_directory = canonical_path(bin_directory, directory=True)
    if not bin_directory.is_relative_to(build_root):
        raise ValueError('Native test bundle outside owning build directory')
    bundle = canonical_path(bin_directory / (bundle_name + '.xctest'), directory=True)
    executable = canonical_path(bundle / 'Contents/MacOS' / bundle_name)
    result = dict(environment)
    result['NO_COLOR'] = '1'
    libraries = []
    testing = toolchain / 'usr/lib/swift/macosx/testing'
    if testing.exists():
        libraries.append(canonical_path(testing, directory=True))
    platform = canonical_path(developer / 'Platforms/MacOSX.platform', directory=True)
    frameworks = [canonical_path(platform / 'Developer/Library' / name, directory=True)
                  for name in ['Frameworks', 'PrivateFrameworks']]
    libraries.append(canonical_path(platform / 'Developer/usr/lib', directory=True))
    for key, paths in [('DYLD_FRAMEWORK_PATH', frameworks), ('DYLD_LIBRARY_PATH', libraries)]:
        result[key] = ':'.join(([result[key]] if result.get(key) else []) + [str(path) for path in paths])
    return helper, bundle, executable, result


def owned_crash_reports(report_directory, output, identities, started):
    retained = []
    for path in sorted(report_directory.glob('*.ips')):
        if len(retained) >= 8:
            break
        if path.is_symlink() or path.stat().st_mtime < started or path.stat().st_size > 2_097_152:
            continue
        try:
            text = path.read_text()
            decoder = json.JSONDecoder()
            header, offset = decoder.raw_decode(text)
            payload, _ = decoder.raw_decode(text[offset:].lstrip())
            pid = payload.get('pid')
            executable = payload.get('procPath')
            launch = datetime.datetime.strptime(payload.get('procLaunch', ''),
                                                '%Y-%m-%d %H:%M:%S.%f %z').timestamp()
            if not any(item[0] == pid and item[3] == executable
                       and abs(launch - (item[1] + item[2] / 1_000_000)) < 0.001
                       for item in identities):
                continue
            destination = output / f'owned-crash-{pid}-{len(retained)}.ips'
            destination.write_text(text)
            retained.append(destination.name)
        except (ValueError, OSError, AttributeError):
            continue
    return retained


def is_testing_process(path):
    return Path(path).name in {'swiftpm-testing', 'swiftpm-testing-helper', 'EdithHostPackageTests'}


def completed_tests(batch, text):
    return batch == 'build' or bool(re.search(
        r'Test run with [1-9][0-9]* tests? (?:in [1-9][0-9]* suites? )?passed|Executed [1-9][0-9]* tests?',
        text))


def run_batch(batch, arguments, directory, deadline, process_factory=subprocess.Popen,
              ownership_factory=OwnedProcesses, clock=time.monotonic, sleep=time.sleep, environment=None,
              testing_process=is_testing_process):
    start = clock()
    wall_start = time.time()
    timed_out = False
    retirement_failed = False
    with (directory / f'{batch}.log').open('wb') as log:
        process = process_factory(arguments, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                                  env=environment)
        ownership = ownership_factory(process.pid, os.getuid())
        try:
            while process.poll() is None:
                ownership.refresh()
                if clock() - start >= deadline or (directory / f'{batch}.log').stat().st_size > 16_777_216:
                    timed_out = True
                    for identity in ownership.refresh():
                        if batch != 'build' and testing_process(identity[3]):
                            if ownership.identity(identity[0]) == identity:
                                subprocess.run(['/usr/bin/sample', str(identity[0]), '3', '-file',
                                                str(directory / f'{batch}-{identity[0]}.sample')],
                                               check=False, timeout=10, stdout=subprocess.DEVNULL,
                                               stderr=subprocess.DEVNULL)
                    ownership.terminate(signal.SIGTERM)
                    break
                sleep(0.5)
            if timed_out:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    ownership.terminate(signal.SIGKILL)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        retirement_failed = True
            else:
                process.wait(timeout=5)
        finally:
            survivors = ownership.refresh()
            if survivors:
                ownership.terminate(signal.SIGTERM)
                sleep(1)
                ownership.terminate(signal.SIGKILL)
    log_path = directory / f'{batch}.log'
    if log_path.stat().st_size > 16_777_216:
        with log_path.open('r+b') as oversized:
            oversized.truncate(16_777_216)
    for sample in directory.glob(f'{batch}-*.sample'):
        if sample.stat().st_size > 8_388_608:
            sample.write_text('Owned process sample exceeded the diagnostic bound.\n')
    text = log_path.read_text(errors='replace')
    tests_completed = completed_tests(batch, text)
    known = list(getattr(ownership, 'known', {}).values())
    conflicts = ownership.conflicts() if hasattr(ownership, 'conflicts') else []
    return {'batch': batch, 'testsCompleted': tests_completed,
            'observedTestingProcess': any(testing_process(item[3]) for item in known),
            'knownOwnedProcesses': [{'pid': item[0], 'startedSeconds': item[1],
                                    'startedMicroseconds': item[2], 'executable': item[3],
                                    'processGroup': item[4],
                                    'discoveredParent': getattr(ownership, 'parents', {}).get(item[0])}
                                   for item in known],
            'unverifiedOwnedProcesses': len(conflicts), 'argv': arguments, 'exitCode': process.returncode,
            'timedOut': timed_out, 'retirementFailed': retirement_failed, 'durationSeconds': round(clock() - start, 3),
            'remainingOwnedProcesses': len(ownership.refresh()),
            'ownedCrashReports': owned_crash_reports(
                Path.home() / 'Library/Logs/DiagnosticReports', directory,
                known, wall_start)}


def main():
    if sys.argv[1:]:
        raise ValueError('Unexpected arguments')
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    admit(os.environ, source)
    directory = Path('local/hosted-host-tests')
    directory.mkdir(parents=True, exist_ok=False, mode=0o700)
    developer = subprocess.check_output(['xcode-select', '-p'], text=True).strip()
    receipt = {'schema': 1, 'sourceCommit': source, 'batches': [], 'toolchain': {}}
    for name, arguments in [('swift', ['swift', '--version']),
                            ('xcode', ['xcodebuild', '-version']),
                            ('sdk', ['xcrun', '--show-sdk-version'])]:
        receipt['toolchain'][name] = subprocess.check_output(arguments, text=True, timeout=30).strip()
    try:
        result = run_batch('build', command('build', developer), directory, 900)
        receipt['batches'].append(result)
        if result['exitCode'] == 0 and not result['timedOut']:
            swift = str(Path(developer) / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift')
            binary_directory = subprocess.check_output(
                [swift, 'build', '--show-bin-path', '--package-path', 'Packages/EdithHost',
                 '--build-system', 'native'], text=True, timeout=30).strip()
            helper, bundle, executable, environment = runtime_contract(
                developer, binary_directory, Path('Packages/EdithHost').resolve(), os.environ)
            receipt['runtime'] = {'helper': str(helper), 'bundle': str(bundle),
                                  'executable': str(executable),
                                  'dyldFrameworkPath': environment['DYLD_FRAMEWORK_PATH'],
                                  'dyldLibraryPath': environment['DYLD_LIBRARY_PATH']}
            for batch in ['transport', 'core', 'ui']:
                result = run_batch(batch, command(batch, developer, helper, executable), directory, 600,
                                   environment=environment)
                receipt['batches'].append(result)
    finally:
        receipt['passed'] = len(receipt['batches']) == 4 and all(
            row['exitCode'] == 0 and row['testsCompleted'] and not row['timedOut']
            and row['remainingOwnedProcesses'] == 0 and row['unverifiedOwnedProcesses'] == 0
            and (row['batch'] == 'build' or row['observedTestingProcess'])
            for row in receipt['batches'])
        (directory / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
