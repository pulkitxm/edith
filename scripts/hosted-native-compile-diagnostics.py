from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time


def admit(environment, source):
    expected = environment.get('EXPECTED_SOURCE_SHA', '')
    conditions = (
        environment.get('GITHUB_ACTIONS') == 'true',
        environment.get('RUNNER_OS') == 'macOS',
        environment.get('RUNNER_ENVIRONMENT') == 'github-hosted',
        environment.get('GITHUB_EVENT_NAME') == 'workflow_dispatch',
        environment.get('GITHUB_REPOSITORY') == 'pulkitxm/edith',
        environment.get('GITHUB_REPOSITORY_ID') == '1289153439',
        environment.get('GITHUB_ACTOR_ID') in ('65671483', '320458784'),
        environment.get('GITHUB_REF') in (
            'refs/heads/feat/extension-marketplace', 'refs/heads/main'),
        re.fullmatch('[0-9a-f]{40}', expected) is not None,
        expected == environment.get('GITHUB_SHA') == source,
    )
    if not all(conditions):
        raise ValueError('native compile diagnostics require exact-source hosted admission')


def compile_command(developer):
    plugins = str(Path(developer) / 'Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins')
    return [
        'swift', 'build', '--package-path', 'Extensions/attention/NativeRuntime',
        '--build-tests', '--build-system', 'native', '--jobs', '1', '-v',
        '-Xswiftc', '-plugin-path', '-Xswiftc', plugins,
    ]


def run_command(command, root, environment, destination, timeout):
    started = time.monotonic()
    timed_out = False
    with destination.open('wb') as output:
        process = subprocess.Popen(
            command, cwd=root, env=environment, stdout=output,
            stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
            code = 124
    return {
        'command': command, 'exit': code, 'timedOut': timed_out,
        'elapsedSeconds': time.monotonic() - started,
        'log': destination.name,
        'logSHA256': hashlib.sha256(destination.read_bytes()).hexdigest(),
    }


def retain_compiler_reports(directory, output, started, finished):
    retained = []
    names = ('swift-frontend', 'swift-driver', 'swift')
    for path in sorted(directory.glob('*')):
        if len(retained) == 4:
            break
        if path.is_symlink() or path.suffix not in ('.ips', '.crash'):
            continue
        stat = path.stat()
        if not path.is_file() or not started <= stat.st_mtime <= finished or stat.st_size > 8_000_000:
            continue
        contents = path.read_bytes()
        text = contents.decode('utf8', errors='replace')
        if path.suffix == '.ips':
            try:
                name = json.loads(text.splitlines()[0]).get('app_name')
            except (ValueError, IndexError):
                continue
        else:
            match = re.search(r'^Process:\s+([^\s]+)\s+\[\d+\]', text, re.MULTILINE)
            name = match.group(1) if match else None
        if name not in names:
            continue
        destination = output / f'compiler-crash-{len(retained)}{path.suffix}'
        destination.write_bytes(contents)
        retained.append({
            'file': destination.name, 'processName': name,
            'sha256': hashlib.sha256(contents).hexdigest(),
        })
    return retained


def main():
    root = Path(__file__).resolve().parent.parent
    source = subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    admit(os.environ, source)
    output = root / 'local/hosted-native-compile'
    output.mkdir(parents=True, exist_ok=False)
    started = time.time()
    reports = Path.home() / 'Library/Logs/DiagnosticReports'
    developer = subprocess.check_output(['xcode-select', '-p'], text=True).strip()
    environment = {
        key: value for key, value in os.environ.items()
        if not key.startswith('EDITH_')
    }
    records = []
    fixture = tempfile.mkdtemp(prefix='edith-compile-', dir=os.environ['RUNNER_TEMP'])
    fixture_home = Path(fixture) / 'home'
    fixture_home.mkdir()
    environment.update({
        'HOME': str(fixture_home), 'CFFIXED_USER_HOME': str(fixture_home),
        'DEVELOPER_DIR': developer,
    })
    outcome = {'source': source, 'productExecution': False, 'commands': records}
    try:
        commands = [
            (['xcodebuild', '-version'], 60), (['swift', '--version'], 60),
            (['xcrun', '--sdk', 'macosx', '--show-sdk-version'], 60),
            (['bun', '--version'], 60),
            (['bun', 'scripts/prepare-extension-native-support.mjs', 'attention'], 300),
            (compile_command(developer), 1200),
        ]
        for index, (command, timeout) in enumerate(commands):
            record = run_command(
                command, root, environment, output / f'command-{index}.log', timeout)
            records.append(record)
            if record['exit'] != 0:
                break
        code = records[-1]['exit']
        outcome['exit'] = code
        outcome['compilerCrashReports'] = retain_compiler_reports(
            reports, output, started, time.time())
    finally:
        (output / 'outcome.json').write_text(json.dumps(outcome, indent=2) + '\n')
        shutil.rmtree(fixture)
    print(json.dumps(outcome))
    raise SystemExit(code if code >= 0 else 128 - code)


if __name__ == '__main__':
    main()
