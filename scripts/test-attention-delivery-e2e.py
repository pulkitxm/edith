import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import uuid

from edith_fixture_copy import copy_fixture_file

from edith_test_environment import isolated_test_environment, test_build_directory

repo = pathlib.Path(__file__).resolve().parents[1]
build = test_build_directory(repo)
root = pathlib.Path(tempfile.mkdtemp(prefix='edith-attention-delivery-')).resolve()
label = 'com.pulkit.edith.test.' + uuid.uuid4().hex
suite = label + '.defaults'
helper_suite = label + '.helper'
env = dict(isolated_test_environment(root, label), EDITH_AGENT_BUILD='attention-delivery-e2e',
           EDITH_ATTENTION_DELIVERY_LIVE='1', EDITH_ATTENTION_DELIVERY_ROOT=str(root),
           EDITH_ATTENTION_DELIVERY_INSTANT=str(int(time.time())))
target = 'gui/' + str(os.getuid()) + '/' + label
plist = root / 'agent.plist'
results = []
booted = False
daemon_pids = set()


def call(arguments, check=True, timeout=30, environment=None):
    result = subprocess.run(arguments, capture_output=True, text=True, env=environment or env,
                            timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(str(arguments) + ': ' + result.stdout + result.stderr)
    return result


def status():
    return json.loads(call([str(root / 'ed'), 'agent', 'status', '--json']).stdout)


def wait_ready(previous_pid=None):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            value = status()
            if value['build'] == 'attention-delivery-e2e' and value['pid'] != previous_pid:
                assert pathlib.Path(value['store']).resolve().parent == root / 'data', value
                daemon_pids.add(value['pid'])
                return value
        except (RuntimeError, json.JSONDecodeError, OSError):
            pass
        time.sleep(0.1)
    raise AssertionError('The private Attention daemon did not become ready.')


def start():
    global booted
    booted = True
    call(['/bin/launchctl', 'bootstrap', 'gui/' + str(os.getuid()), str(plist)])
    return wait_ready()


def stop():
    try:
        job = call(['/bin/launchctl', 'print', target], check=False, timeout=5)
        match = re.search(r'^\s*pid = (\d+)\s*$', job.stdout, re.MULTILINE)
        if match:
            daemon_pids.add(int(match.group(1)))
    finally:
        try:
            call(['/bin/launchctl', 'bootout', target], check=False)
        finally:
            wait_stopped()


def wait_stopped():
    global booted
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        running = any(call(['/bin/ps', '-p', str(pid), '-o', 'comm='], check=False,
                           timeout=5).stdout.strip() == str(root / 'edithd')
                      for pid in daemon_pids)
        if not running and call(['/bin/launchctl', 'print', target], check=False,
                                timeout=5).returncode:
            booted = False
            return
        time.sleep(0.05)
    raise AssertionError('The private Attention service or its daemon did not stop.')


def stage(name):
    environment = dict(env, EDITH_ATTENTION_DELIVERY_STAGE=name)
    result = call([str(test_runner), '--test-bundle-path', str(test_binary),
                   '--testing-library', 'swift-testing', '--filter',
                   'AttentionDeliveryInstalledTests'], timeout=60, environment=environment)
    (root / (name + '.log')).write_text(result.stdout + result.stderr)
    path = root / (name + '.json')
    assert path.is_file(), 'The selected installed test did not publish its result.'
    return json.loads(path.read_text())


def record(name, **details):
    value = dict(test=name, passed=True, **details)
    results.append(value)
    print(json.dumps(value), flush=True)


try:
    source_bundle = build / 'EdithPackageTests.xctest'
    assert source_bundle.is_dir(), 'Build the Debug AttentionDeliveryInstalledTests first.'
    test_bundle = root / source_bundle.name
    shutil.copytree(source_bundle, test_bundle, symlinks=True, copy_function=copy_fixture_file)
    shutil.copytree(build / 'Sparkle.framework', root / 'Sparkle.framework',
                    symlinks=True, copy_function=copy_fixture_file)
    platform = pathlib.Path(call(['/usr/bin/xcrun', '--sdk', 'macosx',
                                  '--show-sdk-platform-path']).stdout.strip()) / 'Developer'
    shutil.copytree(platform / 'Library/Frameworks/Testing.framework',
                    root / 'Testing.framework', symlinks=True, copy_function=copy_fixture_file)
    copy_fixture_file(platform / 'usr/lib/lib_TestingInterop.dylib', root / 'lib_TestingInterop.dylib')
    test_binary = test_bundle / 'Contents/MacOS/EdithPackageTests'
    swift = pathlib.Path(call(['/usr/bin/xcrun', '--find', 'swift']).stdout.strip())
    loader = swift.parent.parent / 'libexec/swift/pm/swiftpm-testing-helper'
    test_runner = root / 'test-runner'
    copy_fixture_file(loader, test_runner)
    call(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier',
          'com.pulkit.edith', str(test_runner)])
    call(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier',
          'com.pulkit.edith', str(test_binary)])
    for name, identity in [('ed', 'ed'), ('edithd', 'com.pulkit.edith.agent')]:
        copy_fixture_file(build / name, root / name)
        call(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', identity, str(root / name)])
    for key in ['suiteAgentsEnabled', 'suiteMaintenanceEnabled', 'suiteSystemEnabled',
                'suiteDeskEnabled', 'suiteMediaEnabled', 'suiteDataEnabled', 'icloudBackup']:
        call(['/usr/bin/defaults', 'write', suite, key, '-bool', 'false'])
    settings = root / 'data/attention/settings.json'
    settings.parent.mkdir(parents=True)
    settings.write_text(json.dumps(dict(enabled=False, trackingEnabled=False,
                                        browserTrackingEnabled=False, windowTitlesEnabled=False,
                                        iCloudBackupEnabled=False, idleThreshold=300,
                                        privacyLevel='domains', serverPort=52728,
                                        serverToken=uuid.uuid4().hex, categories=[], rules=[])))
    plist.write_bytes(plistlib.dumps(dict(
        Label=label, ProgramArguments=[str(root / 'edithd')], MachServices={label: True},
        KeepAlive=True, RunAtLoad=True,
        EnvironmentVariables={key: value for key, value in env.items() if key.startswith('EDITH_')},
        StandardOutPath=str(root / 'stdout.log'), StandardErrorPath=str(root / 'stderr.log'))))
    initial = start()
    stop()
    offline = stage('offline')
    assert offline['pendingEvents'] == 2 and offline['committedSequence'] == 0, offline
    assert offline['lastFailure'], offline
    record('01 helper writer exits with two durable samples while the daemon is unavailable',
           pendingEvents=offline['pendingEvents'])
    spool_file = root / 'data/attention/delivery-spool.json'
    queued = json.loads(spool_file.read_text())
    start()
    recovered = stage('recover')
    assert recovered['pendingEvents'] == 0 and recovered['committedSequence'] == 2, recovered
    record('02 a new writer process drains saved samples and retries an ambiguous reply without double-counting',
           pendingEvents=recovered['pendingEvents'], recordedSeconds=10)
    before = status()
    call([str(root / 'ed'), 'agent', 'restart', '--json'])
    wait_ready(previous_pid=before['pid'])
    restarted = stage('restart')
    assert restarted['pendingEvents'] == 0 and restarted['committedSequence'] == 3, restarted
    final = json.loads(spool_file.read_text())
    assert final['producerID'] == queued['producerID'] and final['nextSequence'] == 4, final
    record('03 daemon and writer restart preserve receipt identity and continue the durable sequence',
           committedSequence=restarted['committedSequence'], recordedSeconds=15)
    delivery = json.loads(call([str(root / 'ed'), 'attention', 'status', '--json']).stdout)['delivery']
    assert delivery['pendingEvents'] == 0 and not delivery['degraded'], delivery
    record('04 CLI delivery diagnostics report the recovered empty queue',
           pendingEvents=delivery['pendingEvents'], degraded=delivery['degraded'])
finally:
    try:
        if booted:
            stop()
    finally:
        try:
            call(['/usr/bin/defaults', 'delete', suite], check=False)
        finally:
            try:
                call(['/usr/bin/defaults', 'delete', helper_suite], check=False)
            finally:
                (root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
                print('Artifacts: ' + str(root), flush=True)
