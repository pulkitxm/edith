import base64
import datetime
import http.server
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid

repo = pathlib.Path(__file__).resolve().parents[1]
root = pathlib.Path(tempfile.mkdtemp(prefix='edith-sites-e2e-'))
label = 'com.pulkit.edith.test.' + uuid.uuid4().hex
suite = label + '.defaults'
helper_suite = label + '.helper'
env = dict(os.environ, EDITH_AGENT_MACH_SERVICE=label, EDITH_SHARED_DEFAULTS_SUITE=suite,
           EDITH_HELPER_DEFAULTS_SUITE=helper_suite, EDITH_DATA_ROOT=str(root / 'data'),
           EDITH_AGENT_BUILD='sites-e2e')
target = 'gui/' + str(os.getuid()) + '/' + label
results = []
booted = False
server = None


def call(arguments, check=True, timeout=25):
    result = subprocess.run(arguments, capture_output=True, text=True, env=env, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(str(arguments) + ': ' + result.stdout + result.stderr)
    return result


def cli(*arguments):
    return json.loads(call([str(root / 'ed'), 'agent', *arguments]).stdout)


def invoke(operation, payload=None, check=True):
    path = root / ('request-' + uuid.uuid4().hex + '.json')
    path.write_text(json.dumps(payload))
    result = call([str(root / 'client'), label, operation, str(path)], check=check)
    if not check:
        return result
    return json.loads(result.stdout) if result.stdout else None


def wait_for(action, predicate, timeout=25):
    deadline = time.monotonic() + timeout
    latest = None
    while time.monotonic() < deadline:
        try:
            latest = action()
            if predicate(latest):
                return latest
        except (RuntimeError, json.JSONDecodeError):
            pass
        time.sleep(0.1)
    raise AssertionError('Site audit state did not settle: ' + repr(latest))


def record(name, **details):
    result = dict(test=name, passed=True, **details)
    results.append(result)
    print(json.dumps(result), flush=True)


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def submit(operation, payload):
    return invoke('task.submit', dict(id=str(uuid.uuid4()), operation=operation,
                  title='Site fixture', payload=base64.b64encode(json.dumps(payload).encode()).decode()))


def inspect(receipt):
    return cli('tasks', 'inspect', receipt['id'], '--json')


class SiteHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/slow'):
            time.sleep(3)
        if self.path == '/robots.txt':
            body = 'Sitemap: ' + origin + '/sitemap.xml\n'
            kind = 'text/plain'
        elif self.path == '/sitemap.xml':
            body = '<urlset><url><loc>' + origin + '/fast</loc></url><url><loc>' + origin + '/slow</loc></url></urlset>'
            kind = 'application/xml'
        else:
            body = '<html lang="en"><head><title>Fixture page</title><meta name="description" content="A fixture page."></head><body><h1>Fixture</h1></body></html>'
            kind = 'text/html'
        encoded = body.encode()
        self.send_response(200)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        try:
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            pass

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
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), SiteHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = 'http://127.0.0.1:' + str(server.server_port)
    plist = root / 'agent.plist'
    plist.write_bytes(plistlib.dumps(dict(
        Label=label, ProgramArguments=[str(root / 'edithd')], MachServices={label: True},
        KeepAlive=True, RunAtLoad=True,
        EnvironmentVariables={key: value for key, value in env.items() if key.startswith('EDITH_')},
        StandardOutPath=str(root / 'stdout.log'), StandardErrorPath=str(root / 'stderr.log'))))
    call(['/bin/launchctl', 'bootstrap', 'gui/' + str(os.getuid()), str(plist)])
    booted = True
    initial = wait_for(lambda: cli('status', '--json'), lambda value: value['build'] == 'sites-e2e')
    assert str(root / 'data') in initial['store']
    discovery = submit('site.discover', origin)
    discovered = wait_for(lambda: inspect(discovery), lambda value: value['snapshot']['state'] == 'succeeded')
    pages = json.loads(base64.b64decode(discovered['result']))
    assert set(pages) == {origin + '/fast', origin + '/slow'}, pages
    record('01 daemon discovers pages from actual robots and sitemap responses')
    project = dict(id=str(uuid.uuid4()), name='Fixture site', baseURL=origin,
                   createdAt=timestamp(), updatedAt=timestamp(), runs=[])
    project = invoke('site.create', project)
    run_id = str(uuid.uuid4())
    receipt = submit('site.audit', dict(projectID=project['id'], runID=run_id,
                     urls=[origin + '/fast', origin + '/slow'], lighthouse=False))
    active = wait_for(lambda: invoke('site.project', project['id']),
                      lambda value: value['runs'] and len(value['runs'][0]['pages']) == 1)
    assert active['runs'][0]['state'] == 'running'
    assert invoke('site.delete', project['id'], check=False).returncode != 0
    wait_for(lambda: inspect(receipt), lambda value: value['snapshot']['state'] == 'succeeded')
    complete = invoke('site.project', project['id'])
    assert complete['runs'][0]['state'] == 'completed'
    assert [page['url'] for page in complete['runs'][0]['pages']] == [origin + '/fast', origin + '/slow']
    assert all(page['metadata']['title'] == 'Fixture page' for page in complete['runs'][0]['pages'])
    record('02 audit survives client exit, publishes partial progress and protects its active project')
    renamed = invoke('site.rename', dict(id=project['id'], name='Verified site'))
    assert renamed['name'] == 'Verified site'
    cancelled = submit('site.audit', dict(projectID=project['id'], runID=str(uuid.uuid4()),
                       urls=[origin + '/fast', origin + '/slow'], lighthouse=False))
    wait_for(lambda: invoke('site.project', project['id']), lambda value: value['runs'] and len(value['runs'][0]['pages']) == 1)
    cli('tasks', 'cancel', cancelled['id'], '--json')
    wait_for(lambda: inspect(cancelled), lambda value: value['snapshot']['state'] == 'cancelled')
    saved = invoke('site.project', project['id'])
    assert saved['runs'][0]['state'] == 'cancelled' and len(saved['runs'][0]['pages']) == 1
    assert saved['runs'][1] == complete['runs'][0]
    record('03 cancellation preserves completed pages and the previous audit history')
    interrupted = submit('site.audit', dict(projectID=project['id'], runID=str(uuid.uuid4()),
                         urls=[origin + '/slow'], lighthouse=False))
    wait_for(lambda: inspect(interrupted), lambda value: value['snapshot']['state'] == 'running')
    cli('restart', '--json')
    wait_for(lambda: cli('status', '--json'), lambda value: value['pid'] != initial['pid'])
    recovered = invoke('site.project', project['id'])
    assert recovered['name'] == 'Verified site'
    assert recovered['runs'][0]['state'] in ['failed', 'cancelled']
    assert recovered['runs'][2] == complete['runs'][0]
    assert inspect(interrupted)['snapshot']['state'] == 'interrupted'
    record('04 restart preserves projects and history and resolves an interrupted audit')
    if '--lighthouse' in sys.argv:
        lighthouse = submit('site.lighthouse', dict(projectID=project['id'], runID=run_id,
                            urls=[origin + '/fast'], lighthouse=True))
        scored = wait_for(lambda: inspect(lighthouse), lambda value: value['snapshot']['state'] in ['succeeded', 'failed'], timeout=210)
        assert scored['snapshot']['state'] == 'succeeded', scored
        scored_project = invoke('site.project', project['id'])
        scored_run = next(run for run in scored_project['runs'] if run['id'].lower() == run_id.lower())
        page = scored_run['pages'][0]
        assert not page.get('lighthouseError'), page.get('lighthouseError')
        assert all(isinstance(page['scores'].get(key), int) for key in ['performance', 'accessibility', 'bestPractices', 'seo']), page['scores']
        record('05 real Lighthouse and headless Chrome produce persisted scores inside the daemon', scores=page['scores'])
    invoke('site.delete', project['id'])
    assert invoke('site.projects') == []
    record('06 daemon deletes an idle project and its saved history')
finally:
    if booted:
        call(['/bin/launchctl', 'bootout', target], check=False)
    if server:
        server.shutdown()
        server.server_close()
    for domain in [suite, helper_suite]:
        call(['/usr/bin/defaults', 'delete', domain], check=False)
    (root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('Artifacts: ' + str(root), flush=True)
