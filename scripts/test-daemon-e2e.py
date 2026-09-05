import base64
import json
import os
import pathlib
import plistlib
import shutil
import statistics
import subprocess
import tempfile
import time
import uuid

repo = pathlib.Path(__file__).resolve().parents[1]
root = pathlib.Path(tempfile.mkdtemp(prefix='edith-daemon-e2e-'))
label = 'com.pulkit.edith.test.' + uuid.uuid4().hex
suite = label + '.defaults'
env = dict(os.environ, EDITH_AGENT_MACH_SERVICE=label, EDITH_SHARED_DEFAULTS_SUITE=suite,
           EDITH_DATA_ROOT=str(root / 'data'), EDITH_AGENT_BUILD='runtime-e2e')
target = 'gui/' + str(os.getuid()) + '/' + label
results = []
booted = False

def call(args, timeout=15, check=True):
    result = subprocess.run(args, text=True, capture_output=True, env=env, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(str(args) + ': ' + result.stderr + result.stdout)
    return result

def cli(*args, check=True):
    return call([str(root / 'ed'), 'agent', *args], check=check)

def value(*args):
    return json.loads(cli(*args).stdout)

def wait_for(action, predicate, timeout=15):
    end = time.monotonic() + timeout
    latest = None
    while time.monotonic() < end:
        try:
            latest = action()
            if predicate(latest):
                return latest
        except (RuntimeError, json.JSONDecodeError):
            pass
        time.sleep(0.2)
    raise AssertionError('Timed out waiting for state: ' + repr(latest))

def submit(script, timeout=60):
    return value('tasks', 'exec', '--detach', '--json', '--timeout', str(timeout), '--', '/bin/sh', '-c', script)

def inspect(identifier):
    return value('tasks', 'inspect', identifier, '--json')

def record(name, **data):
    item = dict(test=name, passed=True, **data)
    results.append(item)
    print(json.dumps(item), flush=True)

try:
    for name, identity in [('ed', 'ed'), ('edithd', 'com.pulkit.edith.agent')]:
        shutil.copy2(repo / 'Packages/Edith/.build/debug' / name, root / name)
        call(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', identity, str(root / name)])
    for key in ['suiteAgentsEnabled', 'suiteMaintenanceEnabled', 'suiteSystemEnabled',
                'suiteDeskEnabled', 'suiteMediaEnabled', 'suiteDataEnabled', 'icloudBackup']:
        call(['/usr/bin/defaults', 'write', suite, key, '-bool', 'false'])
    plist = root / 'agent.plist'
    plist.write_bytes(plistlib.dumps(dict(Label=label, ProgramArguments=[str(root / 'edithd')],
        MachServices={label: True}, KeepAlive=True, RunAtLoad=True,
        EnvironmentVariables={key: env[key] for key in env if key.startswith('EDITH_')},
        StandardOutPath=str(root / 'stdout.log'), StandardErrorPath=str(root / 'stderr.log'))))
    call(['/bin/launchctl', 'bootstrap', 'gui/' + str(os.getuid()), str(plist)])
    booted = True
    initial = wait_for(lambda: value('status', '--json'), lambda item: item['build'] == 'runtime-e2e')
    assert str(root / 'data') in initial['store']
    record('01 isolated launchd service', pid=initial['pid'])
    started = time.monotonic()
    receipt = submit("printf 'started\\n'; sleep 5; printf 'finished after client exit\\n'")
    latency = time.monotonic() - started
    assert latency < 3, latency
    progress = wait_for(lambda: inspect(receipt['id']), lambda item: len(item['output']) > 0)
    assert progress['snapshot']['state'] == 'running'
    finished = wait_for(lambda: inspect(receipt['id']), lambda item: item['snapshot']['state'] == 'succeeded')
    result = json.loads(base64.b64decode(finished['result']))
    assert base64.b64decode(result['standardOutputData']) == b'started\nfinished after client exit\n'
    record('02 task survives client exit and reports live progress', submitSeconds=round(latency, 3))
    failure = cli('tasks', 'exec', '--json', '--', '/bin/sh', '-c', 'exit 7', check=False)
    assert failure.returncode == 7, (failure.returncode, failure.stderr)
    failed = value('tasks', 'ls', '--json')
    assert any(item['state'] == 'failed' and item.get('failureCode') == 'commandExit' for item in failed)
    record('03 nonzero exit is reported as failure')
    cancel = submit("sleep 30 & child=$!; printf '%s\\n' \"$child\"; wait")
    running = wait_for(lambda: inspect(cancel['id']), lambda item: bool(item['output']))
    child = running['output'][0]['text'].strip()
    value('tasks', 'cancel', cancel['id'], '--json')
    wait_for(lambda: inspect(cancel['id']), lambda item: item['snapshot']['state'] == 'cancelled')
    wait_for(lambda: call(['/bin/ps', '-p', child, '-o', 'stat='], check=False),
             lambda result: result.returncode != 0 or result.stdout.strip().startswith('Z'))
    record('04 cancellation stops the child process')
    interrupted = submit("printf 'running before restart\\n'; sleep 30")
    wait_for(lambda: inspect(interrupted['id']), lambda item: item['snapshot']['state'] == 'running')
    cli('restart', '--json')
    restarted = wait_for(lambda: value('status', '--json'), lambda item: item['pid'] != initial['pid'], timeout=25)
    restored = inspect(receipt['id'])
    assert restored['snapshot']['state'] == 'succeeded'
    assert restored['result'] == finished['result']
    assert inspect(interrupted['id'])['snapshot']['state'] == 'interrupted'
    events = value('events', '--json')
    assert len(events) <= 500
    assert sum(item['name'] == 'startup' for item in events) >= 2
    record('05 restart retains completed results and marks interrupted work', pid=restarted['pid'])
    timings = []
    for _ in range(12):
        start = time.monotonic()
        value('status', '--json')
        timings.append(time.monotonic() - start)
    time.sleep(2)
    resources = value('status', '--json')
    record('06 idle resource and request measurements',
           medianStatusMilliseconds=round(statistics.median(timings) * 1000, 2),
           residentMiB=round(resources['residentBytes'] / 1048576, 2),
           recentCPUPercent=round(resources['cpuPercent'], 3))
finally:
    if booted:
        call(['/bin/launchctl', 'bootout', target], check=False)
    call(['/usr/bin/defaults', 'delete', suite], check=False)
    (root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('Artifacts: ' + str(root), flush=True)
