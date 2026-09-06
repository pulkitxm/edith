import base64
import concurrent.futures
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import struct
import subprocess
import tempfile
import time
import uuid
import zlib

from edith_fixture_copy import copy_fixture_file
from edith_test_environment import isolated_test_environment, test_build_directory

repo = pathlib.Path(__file__).resolve().parents[1]
build = test_build_directory(repo)
root = pathlib.Path(tempfile.mkdtemp(prefix='edith-clipboard-e2e-'))
label = 'com.pulkit.edith.test.' + uuid.uuid4().hex
suite = label + '.defaults'
helper_suite = label + '.helper'
env = dict(isolated_test_environment(root, label), EDITH_AGENT_MACH_SERVICE=label, EDITH_SHARED_DEFAULTS_SUITE=suite,
           EDITH_HELPER_DEFAULTS_SUITE=helper_suite, EDITH_DATA_ROOT=str(root / 'data'),
           EDITH_AGENT_BUILD='clipboard-e2e')
service = 'gui/' + str(os.getuid()) + '/' + label
results = []
booted = False
daemon_pids = set()
verification = dict(completed=False, cleanupFailures=[], products={}, sources={})


def call(args, check=True, timeout=20):
    result = subprocess.run(args, capture_output=True, text=True, env=env, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(str(args) + ': ' + result.stdout + result.stderr)
    return result


def cli(*args, check=True):
    return call([str(root / 'ed'), *args], check=check)


def value(*args):
    return json.loads(cli(*args).stdout)


def request(operation, payload, check=True):
    request = root / ('request-' + uuid.uuid4().hex + '.json')
    request.write_text(json.dumps(payload))
    return call([str(root / 'client'), label, operation, str(request)], check=check)


def invoke(operation, payload):
    return json.loads(request(operation, payload).stdout)


def file_identity(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1 << 20), b''):
            digest.update(chunk)
    stat = path.stat()
    return dict(sha256=digest.hexdigest(), bytes=stat.st_size, inode=stat.st_ino,
                modified=stat.st_mtime_ns)


def daemon_status():
    status = value('agent', 'status', '--json')
    daemon_pids.add(status['pid'])
    return status


def process_exited(pid):
    try:
        os.kill(pid, 0)
        return False
    except ProcessLookupError:
        return True


def stop_daemon():
    global booted
    call(['/bin/launchctl', 'bootout', service])
    booted = False
    wait_for(lambda: all(process_exited(pid) for pid in daemon_pids), bool)


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
    verification['head'] = call(['/usr/bin/git', '-C', str(repo), 'rev-parse', 'HEAD']).stdout.strip()
    verification['diffSHA256'] = hashlib.sha256(call([
        '/usr/bin/git', '-C', str(repo), 'diff', 'HEAD']).stdout.encode()).hexdigest()
    for relative in ['scripts/test-clipboard-daemon-e2e.py', 'scripts/edith_fixture_copy.py',
                     'scripts/edith_test_environment.py', 'scripts/fixtures/daemon-xpc-client.swift',
                     'Packages/Edith/Package.resolved',
                     'Packages/Edith/Sources/EdithKit/Features/Clipboard/Services/ClipboardArchive.swift']:
        verification['sources'][relative] = file_identity(repo / relative)
    for binary, identity in [('ed', 'ed'), ('edithd', 'com.pulkit.edith.agent')]:
        original = file_identity(build / binary)
        copy_fixture_file(build / binary, root / binary)
        copied = file_identity(root / binary)
        assert original['sha256'] == copied['sha256'] and original['inode'] != copied['inode']
        call(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', identity, str(root / binary)])
        verification['products'][binary] = dict(source=str(build / binary), original=original,
                                                copied=copied, signed=file_identity(root / binary))
    call(['/usr/bin/swiftc', str(repo / 'scripts/fixtures/daemon-xpc-client.swift'), '-o', str(root / 'client')], timeout=60)
    call(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'ed', str(root / 'client')])
    verification['client'] = file_identity(root / 'client')
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
    booted = True
    call(['/bin/launchctl', 'bootstrap', 'gui/' + str(os.getuid()), str(plist)])
    status = wait_for(daemon_status, lambda item: item['build'] == 'clipboard-e2e')
    assert str(root / 'data') in status['store']
    history = value('clipboard', 'ls', '--json')
    assert len(history) == 3 and history[0]['preview'] == 'third fixture', history
    assert cli('clipboard', 'get', '1').stdout.strip() == 'third fixture'
    record('01 daemon serves stored history and text without launching an app or helper')
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        mutations = list(executor.map(lambda _: value('clipboard', 'pin', '1', '--json'), range(8)))
    assert all(item['pinned'] for item in mutations)
    assert len(value('clipboard', 'ls', '--json')) == 3
    before = daemon_status()['pid']
    cli('agent', 'restart', '--json')
    wait_for(daemon_status, lambda item: item['pid'] != before)
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
    stop_daemon()
    before = index_file.read_bytes()
    unavailable = cli('clipboard', 'unpin', '1', '--json', check=False)
    assert unavailable.returncode != 0
    assert index_file.read_bytes() == before
    record('08 disconnected clients report failure and never mutate storage locally')
    for key, amount in [('clipboardMaxItems', 50_000_000), ('clipboardMaxItemBytes', 100_000_000),
                        ('clipboardMaxAgeDays', 0)]:
        call(['/usr/bin/defaults', 'write', suite, key, '-int', str(amount)])
    payload = b'synthetic shared history payload'
    shared_digest = hashlib.sha256(payload).hexdigest()
    (blobs / (shared_digest + '.txt')).write_bytes(payload)
    entries = []
    large_files = {}
    for number in range(4138):
        large = number < 6
        size = (16 << 20) + number + 1 if large else len(payload)
        digest = shared_digest
        if large:
            path = blobs / (str(uuid.uuid4()) + '.tmp')
            with path.open('wb') as output:
                output.truncate(size)
            digest = file_identity(path)['sha256']
            path = path.rename(blobs / (digest + '.txt'))
            large_files[path.name] = file_identity(path)
        entries.append(dict(id=str(uuid.uuid4()), sha256=digest, types=['public.utf8-plain-text'],
                            ext='txt', createdAt='2026-01-01T00:00:00Z',
                            lastCopiedAt='2026-01-01T00:00:00Z', size=size,
                            preview='synthetic saved item ' + str(number), pinned=False))
    index_file.write_text(''.join(json.dumps(entry) + '\n' for entry in entries))
    before = index_file.read_bytes()
    (root / 'large-history-before.jsonl').write_bytes(before)
    expected_ids = {entry['id'] for entry in entries}
    booted = True
    call(['/bin/launchctl', 'bootstrap', 'gui/' + str(os.getuid()), str(plist)])
    wait_for(daemon_status, lambda item: item['build'] == 'clipboard-e2e')
    history = value('clipboard', 'ls', '--limit', '0', '--json')
    assert len(history) == 4138 and {entry['id'] for entry in history} == expected_ids
    page = invoke('clipboard.snapshot', dict(offset=4097, limit=512, recentlyCreated=False))
    assert page['total'] == 4138 and len(page['entries']) == 41
    assert request('clipboard.blob', entries[0]['id'], check=False).returncode != 0
    assert index_file.read_bytes() == before
    assert all(file_identity(blobs / name) == identity for name, identity in large_files.items())
    (root / 'large-history-page.json').write_text(json.dumps(page, indent=2) + '\n')
    record('09 daemon lists 4138 saved records and pages beyond 4096 while preserving six large payloads')
    added = capture(b'a new bounded native capture', 'txt', 'new capture', ['public.utf8-plain-text'])
    assert request('clipboard.snapshot', dict(offset=4097, limit=512, recentlyCreated=False,
                                             revision=page['revision']), check=False).returncode != 0
    history = value('clipboard', 'ls', '--limit', '0', '--json')
    assert len(history) == 4139 and {entry['id'] for entry in history} == expected_ids | {added}
    before = daemon_status()['pid']
    cli('agent', 'restart', '--json')
    wait_for(daemon_status, lambda item: item['pid'] != before)
    history = value('clipboard', 'ls', '--limit', '0', '--json')
    assert len(history) == 4139 and {entry['id'] for entry in history} == expected_ids | {added}
    assert all(file_identity(blobs / name) == identity for name, identity in large_files.items())
    assert value('clipboard', 'stats', '--json')['count'] == 4139
    (root / 'large-history-after.jsonl').write_bytes(index_file.read_bytes())
    verification['largePayloads'] = large_files
    record('10 capture honors configured retention and all 4139 records survive daemon restart')
    assert len(results) == 10 and all(item['passed'] for item in results)
    verification['completed'] = True
except BaseException as error:
    verification['failure'] = str(error)
    raise
finally:
    if booted:
        try:
            stop_daemon()
        except Exception as error:
            verification['cleanupFailures'].append(str(error))
    verification['daemonProcessesExited'] = False
    verification['serviceRemoved'] = False
    try:
        verification['daemonProcessesExited'] = all(process_exited(pid) for pid in daemon_pids)
        verification['serviceRemoved'] = call(['/bin/launchctl', 'print', service], check=False).returncode != 0
    except Exception as error:
        verification['cleanupFailures'].append('drain verification: ' + str(error))
    for name, product in verification['products'].items():
        product['sourceUnchanged'] = False
        product['copyUnchanged'] = False
        try:
            product['sourceUnchanged'] = file_identity(build / name) == product['original']
            product['copyUnchanged'] = file_identity(root / name) == product['signed']
        except Exception as error:
            verification['cleanupFailures'].append('product verification: ' + str(error))
    verification['sourcesUnchanged'] = False
    try:
        verification['sourcesUnchanged'] = all(file_identity(repo / name) == identity
                                                for name, identity in verification['sources'].items())
    except Exception as error:
        verification['cleanupFailures'].append('source verification: ' + str(error))
    verification['defaultsRetained'] = not (verification['daemonProcessesExited'] and verification['serviceRemoved'])
    if not verification['defaultsRetained']:
        for domain in [suite, helper_suite]:
            try:
                call(['/usr/bin/defaults', 'delete', domain], check=False)
            except Exception as error:
                verification['cleanupFailures'].append('defaults cleanup: ' + str(error))
    (root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    (root / 'verification.json').write_text(json.dumps(verification, indent=2) + '\n')
    print('Artifacts: ' + str(root), flush=True)
    assert not verification['cleanupFailures']
    assert verification['daemonProcessesExited'] and verification['serviceRemoved']
    assert verification['sourcesUnchanged']
    assert all(item['sourceUnchanged'] and item['copyUnchanged'] for item in verification['products'].values())
