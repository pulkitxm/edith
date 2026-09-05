import concurrent.futures
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid

repo = pathlib.Path(__file__).resolve().parents[1]
build = pathlib.Path(os.environ.get('EDITH_TEST_BUILD_DIR', repo / 'Packages/Edith/.build/debug'))
root = pathlib.Path(tempfile.mkdtemp(prefix='edith-clipboard-e2e-'))
label = 'com.pulkit.edith.test.' + uuid.uuid4().hex
suite = label + '.defaults'
helper_suite = label + '.helper'
env = dict(os.environ, EDITH_AGENT_MACH_SERVICE=label, EDITH_SHARED_DEFAULTS_SUITE=suite,
           EDITH_HELPER_DEFAULTS_SUITE=helper_suite, EDITH_DATA_ROOT=str(root / 'data'),
           EDITH_AGENT_BUILD='clipboard-e2e')
service = 'gui/' + str(os.getuid()) + '/' + label
results = []
booted = False


def call(args, check=True, timeout=20):
    result = subprocess.run(args, capture_output=True, text=True, env=env, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(str(args) + ': ' + result.stdout + result.stderr)
    return result


def cli(*args, check=True):
    return call([str(root / 'ed'), *args], check=check)


def value(*args):
    return json.loads(cli(*args).stdout)


def wait_for(action, predicate):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        try:
            result = action()
            if predicate(result):
                return result
        except (RuntimeError, json.JSONDecodeError):
            pass
        time.sleep(0.1)
    raise AssertionError('Daemon state did not settle')


def record(name):
    result = dict(test=name, passed=True)
    results.append(result)
    print(json.dumps(result), flush=True)


try:
    for binary, identity in [('ed', 'ed'), ('edithd', 'com.pulkit.edith.agent')]:
        shutil.copy2(build / binary, root / binary)
        call(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', identity, str(root / binary)])
    for key in ['suiteAgentsEnabled', 'suiteMaintenanceEnabled', 'suiteSystemEnabled',
                'suiteDeskEnabled', 'suiteMediaEnabled', 'suiteDataEnabled', 'icloudBackup']:
        call(['/usr/bin/defaults', 'write', suite, key, '-bool', 'false'])
    archive = root / 'data' / 'clipboard'
    blobs = archive / 'blobs'
    blobs.mkdir(parents=True)
    entries = []
    for index, text in enumerate(['first fixture', 'second fixture', 'third fixture']):
        data = text.encode()
        digest = hashlib.sha256(data).hexdigest()
        (blobs / (digest + '.txt')).write_bytes(data)
        entries.append(dict(id=str(uuid.uuid4()), sha256=digest, types=['public.utf8-plain-text'],
                            ext='txt', createdAt='2026-01-01T00:00:0' + str(index) + 'Z',
                            lastCopiedAt='2026-01-01T00:00:0' + str(index) + 'Z',
                            size=len(data), preview=text, pinned=False))
    index_file = archive / 'index.jsonl'
    index_file.write_text(''.join(json.dumps(entry) + '\n' for entry in entries))
    plist = root / 'agent.plist'
    plist.write_bytes(plistlib.dumps(dict(
        Label=label, ProgramArguments=[str(root / 'edithd')], MachServices={label: True},
        KeepAlive=True, RunAtLoad=True,
        EnvironmentVariables={key: val for key, val in env.items() if key.startswith('EDITH_')},
        StandardOutPath=str(root / 'stdout.log'), StandardErrorPath=str(root / 'stderr.log'))))
    call(['/bin/launchctl', 'bootstrap', 'gui/' + str(os.getuid()), str(plist)])
    booted = True
    status = wait_for(lambda: value('agent', 'status', '--json'), lambda item: item['build'] == 'clipboard-e2e')
    assert str(root / 'data') in status['store']
    history = value('clipboard', 'ls', '--json')
    assert len(history) == 3 and history[0]['preview'] == 'third fixture', history
    assert cli('clipboard', 'get', '1').stdout.strip() == 'third fixture'
    record('01 daemon serves stored history and text without launching an app or helper')
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        mutations = list(executor.map(lambda _: value('clipboard', 'pin', '1', '--json'), range(8)))
    assert all(item['pinned'] for item in mutations)
    assert len(value('clipboard', 'ls', '--json')) == 3
    before = value('agent', 'status', '--json')['pid']
    cli('agent', 'restart', '--json')
    wait_for(lambda: value('agent', 'status', '--json'), lambda item: item['pid'] != before)
    assert value('clipboard', 'ls', '--json')[0]['pinned']
    record('02 concurrent pin requests persist once and survive daemon restart')
    before = index_file.read_bytes()
    preview = value('clipboard', 'clear', '--json')
    assert preview['applied'] is False, preview
    assert index_file.read_bytes() == before
    record('03 destructive preview leaves the archive unchanged')
    cleared = value('clipboard', 'clear', '--keep-pinned', '--yes', '--json')
    assert cleared['removed'] == 2 and cleared['remaining'] == 1, cleared
    stats = value('clipboard', 'stats', '--json')
    assert stats['count'] == 1 and stats['pinned'] == 1, stats
    assert stats['diskBytes'] == len(b'third fixture'), stats
    assert len(list(blobs.iterdir())) == 1
    record('04 daemon clear preserves the pinned entry and removes unreferenced payloads')
    call(['/bin/launchctl', 'bootout', service])
    booted = False
    before = index_file.read_bytes()
    unavailable = cli('clipboard', 'unpin', '1', '--json', check=False)
    assert unavailable.returncode != 0
    assert index_file.read_bytes() == before
    record('05 disconnected clients report failure and never mutate storage locally')
finally:
    if booted:
        call(['/bin/launchctl', 'bootout', service], check=False)
    for domain in [suite, helper_suite]:
        call(['/usr/bin/defaults', 'delete', domain], check=False)
    (root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('Artifacts: ' + str(root), flush=True)
