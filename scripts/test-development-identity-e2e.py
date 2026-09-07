import base64
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import time
import uuid

from edith_test_environment import isolated_test_environment

repo = pathlib.Path(__file__).resolve().parents[1]

root = pathlib.Path(tempfile.mkdtemp(prefix='edith-development-package-smoke-'))
fixture = 'com.pulkit.edith.test.' + uuid.uuid4().hex
env = isolated_test_environment(root, fixture)
env.pop('EDITH_AGENT_MACH_SERVICE')
env.pop('EDITH_DATA_ROOT')
label = 'com.pulkit.edith.development.agent'
target = 'gui/' + str(os.getuid()) + '/' + label
binary = repo / 'dist/Edith.app/Contents/MacOS'
booted = False

def call(args, check=True):
    result = subprocess.run(args, capture_output=True, text=True, env=env, timeout=20)
    if check and result.returncode:
        raise RuntimeError(result.stderr + result.stdout)
    return result

def cli(*args):
    return json.loads(call([str(binary / 'ed'), 'agent', *args, '--json']).stdout)

def wait_for(action, predicate):
    deadline = time.monotonic() + 25
    latest = None
    while time.monotonic() < deadline:
        try:
            latest = action()
            if predicate(latest):
                return latest
        except (RuntimeError, json.JSONDecodeError):
            pass
        time.sleep(0.2)
    raise AssertionError(repr(latest))

try:
    assert call(['/bin/launchctl', 'print', target], check=False).returncode != 0, 'Development daemon already registered; refusing to replace it.'
    for key in ['suiteAgentsEnabled', 'suiteMaintenanceEnabled', 'suiteSystemEnabled', 'suiteDeskEnabled', 'suiteMediaEnabled', 'suiteDataEnabled', 'icloudBackup']:
        call(['/usr/bin/defaults', 'write', env['EDITH_SHARED_DEFAULTS_SUITE'], key, '-bool', 'false'])
    plist = root / 'agent.plist'
    plist.write_bytes(plistlib.dumps(dict(Label=label, ProgramArguments=[str(binary / 'edithd')], MachServices={label: True}, KeepAlive=True, RunAtLoad=True, EnvironmentVariables={key: value for key, value in env.items() if key.startswith('EDITH_')}, StandardOutPath=str(root / 'stdout.log'), StandardErrorPath=str(root / 'stderr.log'))))
    call(['/bin/launchctl', 'bootstrap', 'gui/' + str(os.getuid()), str(plist)])
    booted = True
    status = wait_for(lambda: cli('status'), lambda value: value['pid'] > 0)
    assert str(root / 'home/Library/Application Support/Edith Development') in status['store'], status['store']
    print('PASS: signed packaged client connects to the default development daemon service', flush=True)
    print('PASS: packaged daemon uses an isolated Edith Development data directory', flush=True)
    receipt = json.loads(call([str(binary / 'ed'), 'agent', 'tasks', 'exec', '--detach', '--json', '--', '/bin/sh', '-c', 'sleep 1; printf packaged-development-task']).stdout)
    finished = wait_for(lambda: cli('tasks', 'inspect', receipt['id']), lambda value: value['snapshot']['state'] == 'succeeded')
    result = json.loads(base64.b64decode(finished['result']))
    assert base64.b64decode(result['standardOutputData']) == b'packaged-development-task'
    print('PASS: background task finishes after the submitting client exits', flush=True)
finally:
    if booted:
        call(['/bin/launchctl', 'bootout', target], check=False)
    for key in ['EDITH_SHARED_DEFAULTS_SUITE', 'EDITH_HELPER_DEFAULTS_SUITE']:
        call(['/usr/bin/defaults', 'delete', env[key]], check=False)
    print('Fixture logs: ' + str(root), file=sys.stderr)
