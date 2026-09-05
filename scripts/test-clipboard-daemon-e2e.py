import base64
import concurrent.futures
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import struct
import subprocess
import tempfile
import time
import uuid
import zlib

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


def invoke(operation, payload):
    request = root / ('request-' + uuid.uuid4().hex + '.json')
    request.write_text(json.dumps(payload))
    return json.loads(call([str(root / 'client'), label, operation, str(request)]).stdout)


def capture(data, ext, preview, types):
    identifier = str(uuid.uuid4())
    invoke('clipboard.capture', dict(id=identifier, data=base64.b64encode(data).decode(),
           types=types, ext=ext, preview=preview,
           capturedAt=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')))
    return identifier


def png(width, height):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    raw = (b'\x00' + bytes([34, 108, 220, 255]) * width) * height
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')


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
    call(['/usr/bin/swiftc', str(repo / 'scripts/fixtures/daemon-xpc-client.swift'), '-o', str(root / 'client')], timeout=60)
    call(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'ed', str(root / 'client')])
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
    html = capture(b'<p>Hello &amp; welcome</p>', 'html', 'HTML', ['public.html'])
    image_id = capture(png(1600, 800), 'png', 'PNG image', ['public.png'])
    rendered = invoke('clipboard.thumbnail', dict(id=str(uuid.uuid4()), entryID=image_id))
    image = base64.b64decode(rendered['data'])
    assert struct.unpack('>II', image[16:24]) == (160, 80)
    assert len(image) <= 128 << 10
    (root / 'daemon-thumbnail.png').write_bytes(image)
    again = invoke('clipboard.thumbnail', dict(id=str(uuid.uuid4()), entryID=image_id))
    assert base64.b64decode(again['data']) == image
    record('05 daemon renders and caches a bounded 160 by 80 image thumbnail without a GUI')
    copied = invoke('clipboard.copyPayload', dict(id=html, plainTextOnly=True))
    assert copied['text'] == 'Hello & welcome', copied
    inspection = invoke('clipboard.inspect', False)
    assert inspection['entries'] == 3 and inspection['missingPayloads'] == 0, inspection
    record('06 daemon prepares plain text copies and inspects archive readiness')
    html_digest = hashlib.sha256(b'<p>Hello &amp; welcome</p>').hexdigest()
    (blobs / (html_digest + '.html')).unlink()
    assert invoke('clipboard.inspect', False)['missingPayloads'] == 1
    record('07 archive readiness detects an actually missing payload')
    call(['/bin/launchctl', 'bootout', service])
    booted = False
    before = index_file.read_bytes()
    unavailable = cli('clipboard', 'unpin', '1', '--json', check=False)
    assert unavailable.returncode != 0
    assert index_file.read_bytes() == before
    record('08 disconnected clients report failure and never mutate storage locally')
finally:
    if booted:
        call(['/bin/launchctl', 'bootout', service], check=False)
    for domain in [suite, helper_suite]:
        call(['/usr/bin/defaults', 'delete', domain], check=False)
    (root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('Artifacts: ' + str(root), flush=True)
