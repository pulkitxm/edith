import base64
import datetime
import http.server
import json
import os
import pathlib
import plistlib
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid

repo = pathlib.Path(__file__).resolve().parents[1]
root = pathlib.Path(tempfile.mkdtemp(prefix='edith-attention-e2e-'))
label = 'com.pulkit.edith.test.' + uuid.uuid4().hex
suite = label + '.defaults'
helper_suite = label + '.helper'
env = dict(os.environ, EDITH_AGENT_MACH_SERVICE=label, EDITH_SHARED_DEFAULTS_SUITE=suite,
           EDITH_HELPER_DEFAULTS_SUITE=helper_suite, EDITH_DATA_ROOT=str(root / 'data'),
           EDITH_AGENT_BUILD='attention-e2e')
target = 'gui/' + str(os.getuid()) + '/' + label
results = []
booted = False
icon_server = None


def call(arguments, check=True, timeout=25):
    result = subprocess.run(arguments, capture_output=True, text=True, env=env, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(str(arguments) + ': ' + result.stdout + result.stderr)
    return result


def cli(*arguments):
    return json.loads(call([str(root / 'ed'), 'agent', *arguments]).stdout)


def invoke(operation, payload=None):
    path = root / ('request-' + uuid.uuid4().hex + '.json')
    path.write_text(json.dumps(payload))
    result = call([str(root / 'client'), label, operation, str(path)])
    return json.loads(result.stdout) if result.stdout else None


def wait_for(action, predicate, timeout=25):
    deadline = time.monotonic() + timeout
    latest = None
    while time.monotonic() < deadline:
        try:
            latest = action()
            if predicate(latest):
                return latest
        except (RuntimeError, json.JSONDecodeError, OSError):
            pass
        time.sleep(0.1)
    raise AssertionError('Attention state did not settle: ' + repr(latest))


def record(name, **details):
    result = dict(test=name, passed=True, **details)
    results.append(result)
    print(json.dumps(result), flush=True)


def timestamp(offset=0):
    return (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=offset)).strftime('%Y-%m-%dT%H:%M:%SZ')


def health():
    try:
        with urllib.request.urlopen(address + '/v1/health', timeout=2) as response:
            return response.status == 200
    except (OSError, urllib.error.URLError):
        return False


def heartbeat(token):
    body = dict(timestamp=timestamp(-15), duration=15, presence='active', appName='Fixture Browser',
                url='https://example.com/private?token=hidden', media=[])
    request = urllib.request.Request(address + '/v1/heartbeat', data=json.dumps(body).encode(),
                                     headers={'X-Edith-Token': token}, method='POST')
    try:
        with urllib.request.urlopen(request, timeout=3) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code


def notify_settings():
    source = root / 'notify.swift'
    name = 'com.pulkit.edith.settingsChanged.runtime.' + label
    source.write_text('import Foundation\nDistributedNotificationCenter.default().postNotificationName(Notification.Name(' +
                      json.dumps(name) + '), object: nil, userInfo: nil, deliverImmediately: true)\n')
    call(['/usr/bin/swift', str(source)], timeout=45)


class IconHandler(http.server.BaseHTTPRequestHandler):
    requests = 0
    png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jfZkAAAAASUVORK5CYII=')

    def do_GET(self):
        type(self).requests += 1
        self.send_response(200)
        self.send_header('Content-Type', 'image/png')
        self.send_header('Content-Length', str(len(self.png)))
        self.end_headers()
        self.wfile.write(self.png)

    def log_message(self, *arguments):
        pass


try:
    for name, identity in [('ed', 'ed'), ('edithd', 'com.pulkit.edith.agent')]:
        shutil.copy2(repo / 'Packages/Edith/.build/debug' / name, root / name)
        call(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', identity, str(root / name)])
    call(['/usr/bin/swiftc', str(repo / 'scripts/fixtures/daemon-xpc-client.swift'),
          '-o', str(root / 'client')], timeout=60)
    call(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'ed', str(root / 'client')])
    for key in ['suiteAgentsEnabled', 'suiteMaintenanceEnabled', 'suiteSystemEnabled',
                'suiteDeskEnabled', 'suiteMediaEnabled', 'suiteDataEnabled', 'icloudBackup']:
        call(['/usr/bin/defaults', 'write', suite, key, '-bool', 'false'])
    call(['/usr/bin/defaults', 'write', suite, 'tabAttentionEnabled', '-bool', 'true'])
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    address = 'http://127.0.0.1:' + str(port)
    settings = dict(enabled=True, trackingEnabled=False, browserTrackingEnabled=True,
                    idleThreshold=300, privacyLevel='domains', windowTitlesEnabled=False,
                    iCloudBackupEnabled=False, serverPort=port, serverToken=uuid.uuid4().hex,
                    categories=[], rules=[])
    settings_file = root / 'data/attention/settings.json'
    settings_file.parent.mkdir(parents=True)
    settings_file.write_text(json.dumps(settings))
    plist = root / 'agent.plist'
    plist.write_bytes(plistlib.dumps(dict(
        Label=label, ProgramArguments=[str(root / 'edithd')], MachServices={label: True},
        KeepAlive=True, RunAtLoad=True,
        EnvironmentVariables={key: value for key, value in env.items() if key.startswith('EDITH_')},
        StandardOutPath=str(root / 'stdout.log'), StandardErrorPath=str(root / 'stderr.log'))))
    call(['/bin/launchctl', 'bootstrap', 'gui/' + str(os.getuid()), str(plist)])
    booted = True
    initial = wait_for(lambda: cli('status', '--json'), lambda value: value['build'] == 'attention-e2e')
    assert str(root / 'data') in initial['store']
    wait_for(health, bool)
    record('01 browser listener starts with the daemon while both UI applications are absent')
    assert invoke('attention.hasEvents') is False
    assert heartbeat('wrong-token') == 401
    assert invoke('attention.hasEvents') is False
    record('02 unauthenticated browser events are rejected without storage changes')
    assert heartbeat(settings['serverToken']) == 202
    query = dict(from_=timestamp(-120), to=timestamp(60))
    query['from'] = query.pop('from_')
    summary = invoke('attention.summary', query)
    assert summary['hasStoredEvents'] and len(summary['events']) == 1, summary
    event = summary['events'][0]
    assert event['domain'] == 'example.com' and not event.get('url'), event
    assert summary['summary']['activeDuration'] == 15, summary
    record('03 authenticated heartbeat is stored and summarized with domain privacy')
    cli('restart', '--json')
    wait_for(lambda: cli('status', '--json'), lambda value: value['pid'] != initial['pid'])
    wait_for(health, bool)
    restored = invoke('attention.summary', query)
    assert restored['events'] == summary['events'], restored
    record('04 daemon restart restores the listener and preserves recorded events')
    settings['enabled'] = False
    settings_file.write_text(json.dumps(settings))
    notify_settings()
    wait_for(health, lambda value: not value)
    settings['enabled'] = True
    settings_file.write_text(json.dumps(settings))
    notify_settings()
    wait_for(health, bool)
    record('05 settings changes stop and restart ingestion without opening either UI')
    icon_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), IconHandler)
    threading.Thread(target=icon_server.serve_forever, daemon=True).start()
    icon_url = 'http://127.0.0.1:' + str(icon_server.server_port) + '/favicon.png'
    first_icon = invoke('attention.favicon', icon_url)
    second_icon = invoke('attention.favicon', icon_url)
    assert first_icon and first_icon == second_icon and IconHandler.requests == 1
    decoded = base64.b64decode(first_icon)
    assert decoded.startswith(b'\x89PNG') and len(decoded) <= 131072
    try:
        invoke('attention.favicon', 'file:///etc/hosts')
        raise AssertionError('A local file URL was accepted as a favicon')
    except RuntimeError as error:
        assert 'refused' in str(error) and 'favicon URL is invalid' in str(error)
    record('06 favicon decoding and caching run in the daemon with one bounded network fetch',
           iconBytes=len(decoded), requests=IconHandler.requests)
finally:
    if booted:
        call(['/bin/launchctl', 'bootout', target], check=False)
    if icon_server:
        icon_server.shutdown()
        icon_server.server_close()
    for domain in [suite, helper_suite]:
        call(['/usr/bin/defaults', 'delete', domain], check=False)
    (root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('Artifacts: ' + str(root), flush=True)
