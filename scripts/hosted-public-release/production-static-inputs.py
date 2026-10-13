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



def historical_tag(root, expected):
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
        original = {name: git('show', source + ':' + name) for name in allowed}
        changed = {name: git('show', target + ':' + name) for name in names}
        mode = STATIC.version_child(original, changed, parents, source, version, build, expected['dmgSHA256'])
    for name in ('Resources/Info.plist', 'Resources/HelperInfo.plist'):
        value = plistlib.loads(git('show', target + ':' + name))
        COHORT.require(value['CFBundleShortVersionString'] == version and str(value['CFBundleVersion']) == build, 'Historical tag version differs')
    cask = git('show', target + ':Casks/edith.rb')
    COHORT.require(b'  version "' + version.encode() + b'"\n' in cask and b'  sha256 "' + expected['dmgSHA256'].encode() + b'"\n' in cask, 'Historical tag cask differs from DMG')
    return {'sourceCommit': source, 'tagTargetCommit': target, 'tag': tag, 'tagMode': mode, 'latestMainRequired': False}


def release_tag(root, expected, generation):
    COHORT.require(generation in ['previous', 'current'], 'Wrong release tag generation')
    if generation == 'previous':
        return historical_tag(root, expected)
    return STATIC.qualify_tag(str(root), expected['source'], expected['tag'], expected['version'], str(expected['build']), expected['dmgSHA256'])


def host(context):
    COHORT.exact(context, ['request', 'generation', 'directory'])
    request = COHORT.request(json.dumps(context['request']))
    generation = context['generation']
    COHORT.require(generation in ['previous', 'current'], 'Wrong cohort generation')
    expected = request['hosts'][generation]
    directory = Path(context['directory'])
    COHORT.require(directory.is_absolute() and directory.resolve(strict=True) == directory, 'Noncanonical public input directory')
    proof = STATIC.document(directory / 'host-release-proof.json')
    COHORT.require(STATIC.file_hash(directory / 'host-release-proof.json', 1024**2)['sha256'] == expected['proofSHA256'], 'Host receipt digest differs')
    for key, original in [('source', 'sourceCommit'), ('version', 'version'), ('build', 'build'), ('hostExecutableSHA256', 'hostExecutableSHA256'), ('dmgSHA256', 'dmgSHA256'), ('dmgBytes', 'dmgBytes'), ('appcastSHA256', 'appcastSHA256'), ('installedBytes', 'installedBytes'), ('extensionPayloadBytes', 'extensionPayloadBytes'), ('teamIdentifier', 'teamIdentifier'), ('certificateCategory', 'certificateCategory'), ('designatedRequirement', 'verifiedDesignatedRequirement'), ('notarization', 'notarization')]:
        COHORT.require(str(proof[original]) == str(expected[key]), 'Host receipt identity differs')
    tag_identity = release_tag(ROOT, expected, generation)
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
        identity = code.executable_identity(bundle / 'Contents/MacOS/Edith', expected['normalizedUnsignedSHA256'])
        COHORT.require(identity['signedSHA256'] == expected['hostExecutableSHA256'] and identity['normalization'] == expected['normalization'], 'Host implementation identity differs')
        signed = signing(bundle, expected['teamIdentifier'], expected['designatedRequirement'])
        COHORT.require(STATIC.file_hash(dmg) == {'bytes': expected['dmgBytes'], 'sha256': expected['dmgSHA256']}, 'Public DMG changed during verification')
        return {'generation': generation, 'source': expected['source'], 'dmg': str(dmg), 'tagIdentity': tag_identity, 'publicStaticProof': actual, 'implementation': identity, 'role': {'role': 'host', 'executable': COHORT.EXECUTABLE, **signed}}
    finally:
        if attached:
            command(['hdiutil', 'detach', str(mount)], 120)


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
    parser.add_argument('phase', choices=['host', 'package', 'measure-package'])
    parser.add_argument('context')
    arguments = parser.parse_args()
    context = STATIC.document(arguments.context)
    COHORT.hosted(os.environ, context['template' if arguments.phase == 'measure-package' else 'request']['source'])
    handlers = {'host': host, 'package': package, 'measure-package': measure_package}
    print(json.dumps(handlers[arguments.phase](context)))


if __name__ == '__main__':
    main()
