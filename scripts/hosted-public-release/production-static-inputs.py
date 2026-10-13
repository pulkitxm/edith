import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(value)
    return value


STATIC = module('production_static', Path(__file__).with_name('static-proof.py'))
COHORT = module('production_cohort', Path(__file__).with_name('production-cohort.py'))


def command(arguments, timeout=60):
    return subprocess.check_output(arguments, timeout=timeout, stderr=subprocess.PIPE).decode()


def bounded_owned_bytes(path, maximum):
    COHORT.require(path.is_absolute() and path.resolve(strict=True) == path, 'Noncanonical package input')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        COHORT.require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid() and before.st_nlink == 1 and not before.st_mode & 0o022 and 0 < before.st_size <= maximum, 'Unbounded or unowned package input')
        with os.fdopen(os.dup(descriptor), 'rb') as stream:
            data = stream.read(before.st_size + 1)
        COHORT.require(len(data) == before.st_size and STATIC.signature(before) == STATIC.signature(os.fstat(descriptor)) == STATIC.signature(path.lstat()), 'Package input changed')
        return data
    finally:
        os.close(descriptor)


def signing(path, expected_team, requirement=None):
    arguments = ['codesign', '--verify', '--deep', '--strict', '--verbose=2']
    if requirement is not None:
        arguments.extend(['-R', requirement])
    command(arguments + [str(path)])
    result = subprocess.run(['codesign', '-d', '--verbose=4', str(path)], check=True, capture_output=True, text=True, timeout=60)
    text = result.stderr
    teams = re.findall(r'^TeamIdentifier=([A-Z0-9]{10})$', text, re.M)
    hashes = re.findall(r'^CDHash=([a-f0-9]{40})$', text, re.M)
    COHORT.require(teams == [expected_team] and len(hashes) == 1, 'Signed code ownership differs')
    code_requirement = subprocess.run(['codesign', '-d', '-r-', str(path)], check=True, capture_output=True, text=True, timeout=60).stderr
    requirements = re.findall(r'^designated => (.+)$', code_requirement, re.M)
    COHORT.require(len(requirements) == 1 and len(requirements[0]) <= 4096, 'Missing designated code requirement')
    return {'codeHash': hashes[0], 'requirement': requirements[0]}



def historical_tag(root, expected, *, prerelease=False):
    source, tag, version, build = expected['source'], expected['tag'], expected['version'], str(expected['build'])
    COHORT.require(re.fullmatch('[0-9a-f]{40}', source) and tag == 'v' + version and re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag) and re.fullmatch('[0-9]{1,20}', build), 'Invalid historical release identity')
    def git(*args):
        return subprocess.check_output(['git', '-C', str(root), *args], timeout=60)
    COHORT.require(git('cat-file', '-t', 'refs/tags/' + tag).strip() == b'commit', 'Require raw historical lightweight tag')
    target = git('rev-parse', 'refs/tags/' + tag).decode().strip()
    mode = 'direct-source'
    if target != source:
        parents = git('show', '-s', '--format=%P', target).decode().strip().split()
        COHORT.require(git('show', '-s', '--format=%s', target).decode().strip() == f'Release {tag} [skip ci]', 'Unexpected historical release stamp subject')
        names = git('diff', '--name-only', source, target).decode().splitlines()
        allowed = {'Resources/Info.plist', 'Resources/HelperInfo.plist', 'Casks/edith.rb'}
        COHORT.require(len(names) == len(set(names)) and set(names) <= allowed, 'Unexpected historical release tree changes')
        if prerelease:
            COHORT.require(set(names) <= {'Resources/Info.plist', 'Resources/HelperInfo.plist'}, 'Prerelease changed the stable cask')
        original = {name: git('show', source + ':' + name) for name in allowed}
        changed = {name: git('show', target + ':' + name) for name in names}
        mode = STATIC.version_child(original, changed, parents, source, version, build, expected['dmgSHA256'])
    for name in ('Resources/Info.plist', 'Resources/HelperInfo.plist'):
        value = plistlib.loads(git('show', target + ':' + name))
        COHORT.require(value['CFBundleShortVersionString'] == version and str(value['CFBundleVersion']) == build, 'Historical tag version differs')
    cask = git('show', target + ':Casks/edith.rb')
    if prerelease:
        COHORT.require(cask == git('show', source + ':Casks/edith.rb'), 'Prerelease changed source cask bytes')
    else:
        COHORT.require(b'  version "' + version.encode() + b'"\n' in cask and b'  sha256 "' + expected['dmgSHA256'].encode() + b'"\n' in cask, 'Historical tag cask differs from DMG')
    return {'sourceCommit': source, 'tagTargetCommit': target, 'tag': tag, 'tagMode': mode, 'latestMainRequired': False}


def release_tag(root, expected, generation, release_channel=None):
    COHORT.require(generation in ['previous', 'current'], 'Wrong release tag generation')
    if release_channel is not None:
        COHORT.exact(release_channel, ['id', 'tag_name', 'target_commitish', 'draft', 'prerelease'])
        COHORT.require(type(release_channel['id']) is int and release_channel['id'] > 0 and release_channel['draft'] is False and type(release_channel['prerelease']) is bool and release_channel['tag_name'] == expected['tag'], 'Invalid actual public release channel')
        target = command(['git', '-C', str(root), 'rev-parse', 'refs/tags/' + expected['tag']]).strip()
        COHORT.require(release_channel['target_commitish'] == target, 'Public release target differs from raw tag')
        if release_channel['prerelease']:
            identity = historical_tag(root, expected, prerelease=True)
            if generation == 'current':
                COHORT.require(command(['git', '-C', str(root), 'rev-parse', 'refs/remotes/origin/main']).strip() == target, 'Current prerelease is not latest main')
                identity.pop('latestMainRequired')
                identity['mainMatchesTag'] = True
            return identity
    if generation == 'previous':
        return historical_tag(root, expected)
    return STATIC.qualify_tag(str(root), expected['source'], expected['tag'], expected['version'], str(expected['build']), expected['dmgSHA256'])


def host(context):
    COHORT.exact(context, ['request', 'generation', 'directory'] + (['releaseChannel'] if 'releaseChannel' in context else []))
    generation = context['generation']
    COHORT.require(generation in ['previous', 'current'], 'Wrong cohort generation')
    if context['request'].get('schema') == 2:
        COHORT.require(generation == 'previous', 'Pending current host cannot use strict constructor')
        request = COHORT.bootstrap_template(json.dumps(context['request']))
    else:
        request = COHORT.request(json.dumps(context['request']))
    expected = request['hosts'][generation]
    directory = Path(context['directory'])
    COHORT.require(directory.is_absolute() and directory.resolve(strict=True) == directory, 'Noncanonical public input directory')
    proof = STATIC.document(directory / 'host-release-proof.json')
    COHORT.require(STATIC.file_hash(directory / 'host-release-proof.json', 1024**2)['sha256'] == expected['proofSHA256'], 'Host receipt digest differs')
    for key, original in [('source', 'sourceCommit'), ('version', 'version'), ('build', 'build'), ('hostExecutableSHA256', 'hostExecutableSHA256'), ('dmgSHA256', 'dmgSHA256'), ('dmgBytes', 'dmgBytes'), ('appcastSHA256', 'appcastSHA256'), ('installedBytes', 'installedBytes'), ('extensionPayloadBytes', 'extensionPayloadBytes'), ('teamIdentifier', 'teamIdentifier'), ('certificateCategory', 'certificateCategory'), ('designatedRequirement', 'verifiedDesignatedRequirement'), ('notarization', 'notarization')]:
        COHORT.require(str(proof[original]) == str(expected[key]), 'Host receipt identity differs')
    return inspect_host(directory, expected, generation, context.get('releaseChannel'), expected['normalizedUnsignedSHA256'])


def inspect_host(directory, expected, generation, release_channel, normalized):
    tag_identity = release_tag(ROOT, expected, generation, release_channel)
    dmg = directory / 'Edith.dmg'
    COHORT.require(STATIC.file_hash(dmg) == {'bytes': expected['dmgBytes'], 'sha256': expected['dmgSHA256']}, 'Public DMG differs')
    mount = directory / 'mounted'
    mount.mkdir(mode=0o700)
    attached = False
    try:
        command(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', str(mount), str(dmg)], 120)
        attached = True
        COHORT.require((mount / 'Edith.app').is_dir() and not (mount / 'Edith.app').is_symlink(), 'Public DMG application missing')
        bundle = mount / 'Edith.app'
        verification = directory / 'verification.json'
        value = {'source': expected['source'], 'tag': expected['tag'], 'proof': str(directory / 'host-release-proof.json'), 'metadata': str(directory / 'build-metadata.json'), 'bundle': str(bundle), 'dmg': str(dmg), 'appcast': str(directory / 'appcast.xml')}
        with verification.open('x') as stream:
            os.chmod(verification, 0o600)
            json.dump(value, stream)
        actual = STATIC.public_host(str(ROOT), str(verification))
        code = module('production_code', ROOT / 'scripts/macho_code_identity.py')
        identity = code.executable_identity(bundle / 'Contents/MacOS/Edith', normalized)
        COHORT.require(identity['signedSHA256'] == expected['hostExecutableSHA256'] and identity['normalization'] == expected['normalization'], 'Host implementation identity differs')
        signed = signing(bundle, expected['teamIdentifier'], expected['designatedRequirement'])
        COHORT.require(STATIC.file_hash(dmg) == {'bytes': expected['dmgBytes'], 'sha256': expected['dmgSHA256']}, 'Public DMG changed during verification')
        result = {'deepStrictSignatureVerified': True, 'generation': generation, 'source': expected['source'], 'dmg': str(dmg), 'tagIdentity': tag_identity, 'publicStaticProof': actual, 'implementation': identity, 'role': {'role': 'host', 'executable': COHORT.EXECUTABLE, **signed}}
        if release_channel is not None:
            result['releaseChannel'] = release_channel
        return result
    finally:
        if attached:
            command(['hdiutil', 'detach', str(mount)], 120)


def completed_host_publication(publication, pending, directory, channel):
    COHORT.exact(publication, ['run', 'jobs', 'release', 'tag'])
    run = publication['run']
    COHORT.exact(run, ['id', 'run_attempt', 'head_sha', 'head_branch', 'event', 'path', 'repository', 'actor', 'status', 'conclusion'])
    COHORT.exact(run['repository'], ['id', 'full_name'])
    COHORT.exact(run['actor'], ['id'])
    COHORT.require(type(run['actor']['id']) is int and run['actor']['id'] in [65671483, 320458784]
                   and type(run['repository']['id']) is int and run['repository']['id'] == 1289153439
                   and run['repository']['full_name'] == 'pulkitxm/edith', 'Completed host repository or actor differs')
    for name, expected in [('id', pending['run']), ('run_attempt', pending['runAttempt']), ('head_sha', pending['source']), ('head_branch', 'main'), ('event', 'workflow_dispatch'), ('path', '.github/workflows/ci.yml'), ('status', 'completed'), ('conclusion', 'success')]:
        COHORT.require(type(run[name]) is type(expected) and run[name] == expected, 'Host run is not the exact completed attempt')
    jobs = publication['jobs']
    COHORT.exact(jobs, ['total_count', 'jobs'])
    COHORT.require(type(jobs['jobs']) is list and 0 < len(jobs['jobs']) <= 1000
                   and type(jobs['total_count']) is int and jobs['total_count'] == len(jobs['jobs']), 'Host job inventory is incomplete')
    identities = []
    for job in jobs['jobs']:
        COHORT.exact(job, ['id', 'run_id', 'run_attempt', 'head_sha', 'name', 'status', 'conclusion'])
        COHORT.positive(job['id'])
        identities.append(job['id'])
        COHORT.require(type(job['run_id']) is int and job['run_id'] == pending['run']
                       and type(job['run_attempt']) is int and job['run_attempt'] == pending['runAttempt']
                       and job['head_sha'] == pending['source'] and type(job['name']) is str
                       and 0 < len(job['name'].encode()) <= 256 and '\n' not in job['name'] and '\r' not in job['name']
                       and job['status'] == 'completed'
                       and job['conclusion'] in ['success', 'skipped', 'neutral'], 'Host job belongs to another attempt or failed')
    COHORT.require(len(identities) == len(set(identities)), 'Duplicate host jobs')
    for name in ['Build DMG', 'Publish release']:
        selected = [job for job in jobs['jobs'] if job['name'] == name]
        COHORT.require(len(selected) == 1 and selected[0]['conclusion'] == 'success', 'Required host job did not succeed')
    release, tag = publication['release'], publication['tag']
    COHORT.exact(release, ['id', 'tag_name', 'target_commitish', 'draft', 'prerelease', 'assets'])
    COHORT.exact(tag, ['ref', 'object'])
    COHORT.exact(tag['object'], ['type', 'sha'])
    COHORT.source(tag['object']['sha'])
    COHORT.require(tag['ref'] == 'refs/tags/' + pending['tag'] and tag['object']['type'] == 'commit'
                   and release['target_commitish'] == tag['object']['sha'], 'Completed public host tag differs')
    COHORT.positive(release['id'])
    COHORT.require({key: release[key] for key in ['id', 'tag_name', 'target_commitish', 'draft', 'prerelease']} == channel
                   and type(release['id']) is int and release['id'] > 0
                   and release['tag_name'] == pending['tag'] and release['draft'] is False
                   and type(release['prerelease']) is bool, 'Actual release channel differs')
    names = {'Edith.dmg', 'appcast.xml', 'host-release-proof.json', 'build-metadata.json', 'toolchain-provenance.json'}
    COHORT.require(type(release['assets']) is list and len(release['assets']) == len(names), 'Wrong completed host assets')
    ids, found, pins = [], [], {}
    for asset in release['assets']:
        COHORT.exact(asset, ['id', 'name', 'size', 'digest', 'state', 'browser_download_url'])
        COHORT.positive(asset['id'])
        COHORT.positive(asset['size'], 2*1024**3)
        COHORT.require(asset['name'] in names and asset['state'] == 'uploaded'
                       and asset['browser_download_url'] == 'https://github.com/pulkitxm/edith/releases/download/' + pending['tag'] + '/' + asset['name'], 'Host asset is not immutable public input')
        maximum = 2*1024**3 if asset['name'] == 'Edith.dmg' else 1024**2
        pin = STATIC.file_hash(directory / asset['name'], maximum)
        COHORT.require(pin['bytes'] == asset['size'] and asset['digest'] == 'sha256:' + pin['sha256'], 'Downloaded host asset differs from actual publication')
        ids.append(asset['id'])
        found.append(asset['name'])
        pins[asset['name']] = (maximum, pin)
    COHORT.require(len(set(ids)) == len(ids) and set(found) == names, 'Duplicate completed host assets')
    return {'tag': tag['object']['sha'], 'release': release['id'], 'pins': pins}


def measure_host(context):
    COHORT.exact(context, ['template', 'generation', 'directory', 'releaseChannel', 'publication'])
    COHORT.require(context['generation'] == 'current', 'Only current completed public host is measured')
    template = COHORT.bootstrap_template(json.dumps(context['template']))
    pending = template['hosts']['current']
    COHORT.positive(pending['run'])
    COHORT.positive(pending['runAttempt'])
    directory = Path(context['directory'])
    COHORT.require(directory.is_absolute() and directory.resolve(strict=True) == directory, 'Noncanonical measured host directory')
    status = directory.lstat()
    COHORT.require(stat.S_ISDIR(status.st_mode) and status.st_uid == os.getuid() and stat.S_IMODE(status.st_mode) == 0o700, 'Require owned private measured host directory')
    publication = completed_host_publication(context['publication'], pending, directory, context['releaseChannel'])
    proof_path = directory / 'host-release-proof.json'
    proof_pin = STATIC.file_hash(proof_path, 1024**2)
    proof = STATIC.document(proof_path)
    for name, expected in [('sourceCommit', pending['source']), ('workflowSourceCommit', pending['source']), ('version', pending['version']), ('build', str(pending['build']))]:
        COHORT.require(str(proof[name]) == expected, 'Measured public host differs from pending intent')
    expected = {key: pending[key] for key in ['source', 'run', 'tag', 'version', 'build']}
    expected['proofSHA256'] = proof_pin['sha256']
    for name in ['dmgURL', 'dmgSHA256', 'dmgBytes', 'appcastSHA256', 'hostExecutableSHA256', 'installedBytes', 'extensionPayloadBytes', 'teamIdentifier', 'certificateCategory', 'notarization']:
        expected[name] = proof[name]
    expected['designatedRequirement'] = proof['verifiedDesignatedRequirement']
    previous = template['hosts']['previous']
    for name in ['teamIdentifier', 'certificateCategory', 'designatedRequirement']:
        COHORT.require(expected[name] == previous[name], 'Measured host trust differs from previous generation')
    expected['hostABI'] = previous['hostABI']
    metadata = STATIC.document(directory / 'build-metadata.json')
    expected['architecture'] = metadata['architecture']
    expected['normalization'] = 'arm64-terminal-linkedit-vmsize-after-verified-signature-removal-v1'
    qualification = inspect_host(directory, expected, 'current', context['releaseChannel'], None)
    expected['normalizedUnsignedSHA256'] = qualification['implementation']['normalizedUnsignedSHA256']
    COHORT.require(expected['normalizedUnsignedSHA256'] != previous['normalizedUnsignedSHA256'], 'Measured host implementation did not change')
    expected['deepStrictSignatureVerified'] = qualification['deepStrictSignatureVerified']
    expected['sparkleEd25519Verified'] = qualification['publicStaticProof']['sparkleEd25519Verified']
    COHORT.require(qualification['tagIdentity']['tagTargetCommit'] == publication['tag'], 'Native host tag differs from actual publication')
    expected['publicationVerified'] = context['publication']['run']['status'] == 'completed' and context['publication']['run']['conclusion'] == 'success'
    for name, (maximum, pin) in publication['pins'].items():
        COHORT.require(STATIC.file_hash(directory / name, maximum) == pin, 'Completed public host asset changed during inspection')
    COHORT.require(STATIC.file_hash(proof_path, 1024**2) == proof_pin, 'Measured public host receipt changed')
    COHORT.host(expected)
    return {'host': expected, 'qualification': qualification}


def extracted_package(directory, expected):
    archive = directory / 'keepAwake.zip'
    metrics = STATIC.archive_metrics(archive, 'keepAwake', expected['downloadBytes'], expected['archiveSHA256'])
    COHORT.require(metrics['installedBytes'] == expected['installedBytes'], 'Public package size differs')
    extracted = directory / 'extracted'
    extracted.mkdir(mode=0o700)
    with STATIC.regular_file(archive, 512 * 1024**2) as stream, zipfile.ZipFile(stream) as source:
        for entry in source.infolist():
            target = extracted / entry.filename
            if entry.is_dir():
                target.mkdir(mode=0o700, parents=True, exist_ok=True)
                continue
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with source.open(entry) as original, target.open('xb') as destination:
                os.chmod(target, (entry.external_attr >> 16) & 0o777 or 0o600)
                total = 0
                while chunk := original.read(min(1024**2, entry.file_size - total + 1)):
                    total += len(chunk)
                    COHORT.require(total <= entry.file_size, 'Archive member grew')
                    destination.write(chunk)
                COHORT.require(total == entry.file_size, 'Truncated archive member')
    payload = extracted / 'keepAwake'
    pins = {}
    def read(path, maximum):
        value = bounded_owned_bytes(path, maximum)
        pins[path] = (maximum, value)
        return value
    return payload, metrics, pins, read


def package(context):
    COHORT.exact(context, ['request', 'generation', 'directory'])
    request = COHORT.request(json.dumps(context['request']))
    generation = context['generation']
    COHORT.require(generation in ['previous', 'current'], 'Wrong cohort generation')
    expected = request['packages'][generation]
    host_expected = request['hosts']['previous']
    directory = Path(context['directory'])
    archive = directory / 'keepAwake.zip'
    payload, metrics, pins, read = extracted_package(directory, expected)
    manifest = json.loads(read(payload / 'package.json', 65536), object_pairs_hook=STATIC.unique_object)
    for key in ['id', 'version', 'hostABI', 'architecture', 'minimumSystemVersion', 'dependencies']:
        COHORT.require(manifest[key] == expected[key], 'Installed package metadata differs')
    worker = expected['workerContract']
    paths = {'engine': payload / 'ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/keepAwake/helper.bundle', 'managedUI': payload / 'ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex', 'carrier': payload / 'ExtensionCarrier.app'}
    executables = {'engine': paths['engine'] / 'Contents/MacOS/Runtime', 'managedUI': paths['managedUI'] / 'Contents/MacOS/Edith', 'carrier': paths['carrier'] / 'Contents/MacOS/Edith'}
    signed = {}
    for role, bundle in paths.items():
        field = {'engine': 'helperSHA256', 'managedUI': 'uiSHA256', 'carrier': 'carrierSHA256'}[role]
        COHORT.require(hashlib.sha256(read(executables[role], 16 * 1024**2)).hexdigest() == worker[field], 'Package executable digest differs')
        signed[role] = signing(bundle, host_expected['teamIdentifier'])
    for role in ['managedUI', 'carrier']:
        info = plistlib.loads(read(paths[role] / 'Contents/Info.plist', 65536))
        expected_id = 'com.pulkit.edith.extension.keepAwake' + ('.worker' if role == 'managedUI' else '')
        COHORT.require(info['CFBundleIdentifier'] == expected_id, 'Wrong production UI identifier')
        attributes = info
        if role == 'managedUI':
            COHORT.require(info['EXAppExtensionAttributes']['EXExtensionPointIdentifier'] == 'com.pulkit.edith.ExtensionUI', 'Wrong extension point')
        for key, value in {'EdithHostIdentifier': 'com.pulkit.edith', 'EdithExtensionID': 'keepAwake', 'EdithExtensionVersion': expected['version'], 'EdithHostABI': 'edith-host-2', 'EdithExecutableProvenance': worker['frozenHostSHA256'], 'EdithCarrierExecutableProvenance': worker['carrierInputSHA256'], 'EdithHostCodeRequirement': host_expected['designatedRequirement'], 'EdithHostExecutablePath': COHORT.EXECUTABLE, 'EdithPayloadRelativePath': 'Contents/Resources/Payload'}.items():
            COHORT.require(attributes[key] == value, 'Current production worker contract differs')
    prefix = Path.home() / 'Library/Application Support/Edith/Extensions/keepAwake/edith-host-2/arm64' / expected['version'] / 'keepAwake'
    managed = {'role': 'managedUI', 'executable': str(prefix / worker['uiExecutable']), **signed['managedUI']}
    COHORT.require(STATIC.archive_metrics(archive, 'keepAwake', expected['downloadBytes'], expected['archiveSHA256']) == metrics, 'Package archive changed')
    for path, (maximum, value) in pins.items():
        COHORT.require(bounded_owned_bytes(path, maximum) == value, 'Verified package input changed')
    return {'generation': generation, 'version': expected['version'], 'archive': str(archive), 'metrics': metrics, 'managedUIRole': managed}



def measure_package(context):
    COHORT.exact(context, ['template', 'record', 'lineage', 'directory'])
    template = COHORT.preparation_template(json.dumps(context['template']))
    record = context['record']
    COHORT.exact(record, ['id', 'version', 'hostABI', 'architecture', 'minimumSystemVersion', 'dependencies', 'downloadURL', 'sha256', 'downloadBytes', 'installedBytes', 'sourceFingerprint'])
    lineage = context['lineage']
    COHORT.require(lineage['package'] == record and lineage['sourceCommit'] == template['source'], 'Current package lineage differs')
    COHORT.positive(lineage['runID'])
    expected = {key: record[key] for key in ['id', 'version', 'hostABI', 'architecture', 'minimumSystemVersion', 'dependencies', 'downloadBytes', 'installedBytes', 'sourceFingerprint']}
    expected.update(source=lineage['sourceCommit'], run=lineage['runID'], archiveURL=record['downloadURL'], archiveSHA256=record['sha256'])
    COHORT.require(expected['id'] == 'keepAwake' and expected['version'] == '1.0.1', 'Wrong measured Keep generation')
    directory = Path(context['directory'])
    payload, metrics, pins, read = extracted_package(directory, expected)
    manifest = json.loads(read(payload / 'package.json', 65536), object_pairs_hook=STATIC.unique_object)
    for key in ['id', 'version', 'hostABI', 'architecture', 'minimumSystemVersion', 'dependencies']:
        COHORT.require(manifest[key] == expected[key], 'Measured package metadata differs')
    paths = {'engine': payload / 'ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/keepAwake/helper.bundle', 'managedUI': payload / 'ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex', 'carrier': payload / 'ExtensionCarrier.app'}
    executables = {'engine': paths['engine'] / 'Contents/MacOS/Runtime', 'managedUI': paths['managedUI'] / 'Contents/MacOS/Edith', 'carrier': paths['carrier'] / 'Contents/MacOS/Edith'}
    host = template['hosts']['previous']
    worker = {'schema': 2, 'helperExecutable': 'ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/keepAwake/helper.bundle/Contents/MacOS/Runtime', 'uiExecutable': 'ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/MacOS/Edith'}
    for role, bundle in paths.items():
        field = {'engine': 'helperSHA256', 'managedUI': 'uiSHA256', 'carrier': 'carrierSHA256'}[role]
        worker[field] = hashlib.sha256(read(executables[role], 16 * 1024**2)).hexdigest()
        signing(bundle, host['teamIdentifier'])
    for role in ['managedUI', 'carrier']:
        info = plistlib.loads(read(paths[role] / 'Contents/Info.plist', 65536))
        identifier = 'com.pulkit.edith.extension.keepAwake' + ('.worker' if role == 'managedUI' else '')
        COHORT.require(info['CFBundleIdentifier'] == identifier, 'Wrong measured production identifier')
        if role == 'managedUI':
            COHORT.require(info['EXAppExtensionAttributes']['EXExtensionPointIdentifier'] == 'com.pulkit.edith.ExtensionUI', 'Wrong measured extension point')
        values = {'carrierInputSHA256': info['EdithCarrierExecutableProvenance'], 'frozenHostSHA256': info['EdithExecutableProvenance'], 'packagedHostRequirement': info['EdithHostCodeRequirement']}
        if role == 'carrier':
            COHORT.require(all(worker[key] == value for key, value in values.items()), 'Measured worker provenance differs')
        worker.update(values)
        for key, value in {'EdithHostIdentifier': 'com.pulkit.edith', 'EdithExtensionID': 'keepAwake', 'EdithExtensionVersion': expected['version'], 'EdithHostABI': 'edith-host-2', 'EdithHostCodeRequirement': host['designatedRequirement'], 'EdithHostExecutablePath': COHORT.EXECUTABLE, 'EdithPayloadRelativePath': 'Contents/Resources/Payload'}.items():
            COHORT.require(info[key] == value, 'Measured production worker contract differs')
    worker['signatureVerified'] = True
    expected['workerContract'] = worker
    COHORT.package(expected, '1.0.1')
    COHORT.require(STATIC.archive_metrics(directory / 'keepAwake.zip', 'keepAwake', expected['downloadBytes'], expected['archiveSHA256']) == metrics, 'Measured package archive changed')
    for path, (maximum, value) in pins.items():
        COHORT.require(bounded_owned_bytes(path, maximum) == value, 'Measured package input changed')
    return expected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('phase', choices=['host', 'package', 'measure-package', 'measure-host'])
    parser.add_argument('context')
    arguments = parser.parse_args()
    context = STATIC.document(arguments.context)
    COHORT.hosted(os.environ, context['template' if arguments.phase in ['measure-package', 'measure-host'] else 'request']['source'])
    handlers = {'host': host, 'package': package, 'measure-package': measure_package, 'measure-host': measure_host}
    print(json.dumps(handlers[arguments.phase](context)))


if __name__ == '__main__':
    main()
