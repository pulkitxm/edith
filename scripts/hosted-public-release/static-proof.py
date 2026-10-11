import argparse
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import zipfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def signature(info):
    return (info.st_dev, info.st_ino, info.st_uid, info.st_mode, info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


@contextmanager
def regular_file(path, maximum):
    path = Path(path)
    require(path.is_absolute() and str(path.resolve(strict=True)) == str(path), 'Require a canonical existing file')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid() and before.st_nlink == 1 and stat.S_IMODE(before.st_mode) == 0o600 and 0 < before.st_size <= maximum, 'Require a bounded private regular file')
        with os.fdopen(os.dup(descriptor), 'rb') as stream:
            yield stream
        require(signature(before) == signature(os.fstat(descriptor)) == signature(path.lstat()), 'File changed during verification')
    finally:
        os.close(descriptor)


def file_hash(path, maximum=1024**3, after_read=lambda: None):
    with regular_file(path, maximum) as stream:
        digest = hashlib.sha256()
        expected_size = os.fstat(stream.fileno()).st_size
        total = 0
        while chunk := stream.read(1024 * 1024):
            total += len(chunk)
            require(total <= expected_size, 'File grew during bounded verification')
            digest.update(chunk)
        size = stream.tell()
        after_read()
    return {'bytes': size, 'sha256': digest.hexdigest()}


def unique_object(pairs):
    result = {}
    for name, value in pairs:
        require(name not in result, 'Duplicate document key')
        result[name] = value
    return result


def document(path):
    with regular_file(path, 4*1024**2) as stream:
        data = stream.read(4*1024**2+1)
        require(len(data) <= 4*1024**2, 'Document grew beyond bound')
        return json.loads(data, object_pairs_hook=unique_object, parse_constant=lambda _: require(False, 'Invalid JSON constant'))


def archive_metrics(path, identifier, expected_bytes, expected_sha256):
    require(re.fullmatch('[A-Za-z][A-Za-z0-9_-]{0,63}', identifier), 'Invalid owner')
    value = file_hash(path, 512*1024**2)
    require(value == {'bytes': expected_bytes, 'sha256': expected_sha256}, 'Archive differs from pinned bytes')
    with regular_file(path, 512*1024**2) as stream, zipfile.ZipFile(stream) as archive:
        entries = archive.infolist()
        require(0 < len(entries) <= 100000 and len({entry.filename for entry in entries}) == len(entries), 'Invalid archive inventory')
        total = 0
        for entry in entries:
            parts = entry.filename.rstrip('/').split('/')
            require(parts[0] == identifier and all(part not in ('', '.', '..') for part in parts) and '\\' not in entry.filename and '\0' not in entry.filename, 'Unsafe archive path')
            kind = stat.S_IFMT(entry.external_attr >> 16)
            require(kind in (0, stat.S_IFREG, stat.S_IFDIR) and not entry.flag_bits & 1, 'Invalid archive member type')
            total += entry.file_size
            require(total <= 1024**3, 'Archive expanded size exceeds limit')
        require(archive.testzip() is None, 'Archive CRC differs')
    require(file_hash(path, 512*1024**2) == value, 'Archive changed after CRC verification')
    return {'id': identifier, 'downloadBytes': value['bytes'], 'sha256': value['sha256'], 'installedBytes': total, 'members': len(entries), 'zipCRCVerified': True, 'codeExecuted': False}


def plan_archive(path, expected_path):
    expected = document(expected_path)
    require(set(expected) == {'include'} and isinstance(expected['include'], list) and len(expected['include']) == 39 and len({row['id'] for row in expected['include']}) == 39, 'Expected source plan must contain exactly39 owners')
    with regular_file(path, 4*1024**2) as stream, zipfile.ZipFile(stream) as archive:
        entries = archive.infolist()
        names = {entry.filename for entry in entries}
        require(0 < len(entries) <= 3 and len(names) == len(entries) and names <= {'plan.json','previous.json','previous-state.json'} and 'plan.json' in names, 'Invalid plan artifact inventory')
        for entry in entries:
            require(stat.S_IFMT(entry.external_attr >> 16) in (0,stat.S_IFREG) and not entry.flag_bits & 1 and 0 < entry.file_size <= 1024**2, 'Invalid plan artifact member')
        require(archive.testzip() is None, 'Plan artifact CRC differs')
        data = archive.read('plan.json')
        actual = json.loads(data, object_pairs_hook=unique_object, parse_constant=lambda _: require(False,'Invalid plan constant'))
        require(actual == expected, 'Actual CI plan differs from exact source39 plan')
    return {'owners':39,'planSHA256':hashlib.sha256(data).hexdigest(),'zipCRCVerified':True}


def version_child(original, changed, parents, source, version, build, dmg_sha256):
    require(parents == [source], 'Release stamp requires exactly one built-source parent')
    require(0 < len(changed) <= 3 and set(changed) <= {'Resources/Info.plist', 'Resources/HelperInfo.plist', 'Casks/edith.rb'}, 'Unexpected release-stamp tree changes')
    for name, actual in changed.items():
        before = original[name]
        if name.endswith('.plist'):
            original_info = plistlib.loads(before)
            expected = dict(original_info)
            expected.update(CFBundleShortVersionString=version, CFBundleVersion=build)
            require(expected != original_info and plistlib.loads(actual) == expected, 'Release stamp changed a nonversion plist field or rewrote an already stamped file')
        else:
            expected, versions = re.subn(rb'^  version ".*"$', b'  version "'+version.encode()+b'"', before, flags=re.M)
            expected, hashes = re.subn(rb'^  sha256 ".*"$', b'  sha256 "'+dmg_sha256.encode()+b'"', expected, flags=re.M)
            require(versions == hashes == 1 and actual == expected, 'Release stamp changed more than exact cask version and DMG checksum')
        require(actual != before, 'Changed-file inventory contains an unchanged file')
    return 'version-stamp-child'


def qualify_tag(root, source, tag, version, build, dmg_sha256):
    require(re.fullmatch('[0-9a-f]{40}', source) and re.fullmatch('v[0-9]+\.[0-9]+\.[0-9]+', tag) and tag == 'v'+version and re.fullmatch('[0-9]{1,20}', build) and re.fullmatch('[0-9a-f]{64}', dmg_sha256), 'Invalid pinned release identity')
    def git(*args):
        return subprocess.check_output(['git', '-C', str(root), *args], timeout=60)
    require(git('cat-file', '-t', 'refs/tags/'+tag).strip() == b'commit', 'Require a raw lightweight commit tag')
    target = git('rev-parse', 'refs/tags/'+tag).decode().strip()
    require(git('rev-parse', 'refs/remotes/origin/main').decode().strip() == target, 'Public main must be the exact pinned release target')
    mode = 'direct-source'
    if target != source:
        parents = git('show', '-s', '--format=%P', target).decode().strip().split()
        require(git('show', '-s', '--format=%s', target).decode().strip() == f'Release {tag} [skip ci]', 'Unexpected release stamp subject')
        names = git('diff', '--name-only', source, target).decode().splitlines()
        require(len(names) == len(set(names)), 'Duplicate release tree changes')
        allowed = {'Resources/Info.plist', 'Resources/HelperInfo.plist', 'Casks/edith.rb'}
        require(set(names) <= allowed, 'Unexpected release tree changes')
        original = {name: git('show', source+':'+name) for name in allowed}
        changed = {name: git('show', target+':'+name) for name in names}
        mode = version_child(original, changed, parents, source, version, build, dmg_sha256)
    for name in ('Resources/Info.plist', 'Resources/HelperInfo.plist'):
        value = plistlib.loads(git('show', target+':'+name))
        require(value['CFBundleShortVersionString'] == version and str(value['CFBundleVersion']) == build, 'Tag version differs')
    cask = git('show', target+':Casks/edith.rb')
    require(b'  version "'+version.encode()+b'"\n' in cask and b'  sha256 "'+dmg_sha256.encode()+b'"\n' in cask, 'Tag cask differs from actual DMG')
    return {'sourceCommit': source, 'tagTargetCommit': target, 'tag': tag, 'tagMode': mode, 'mainMatchesTag': True}


def host_proof(value, source, version, build, index_sha256, sparkle_key, team, certificate, dmg, appcast):
    expected_keys = {'schema','sourceCommit','version','build','installedBytes','extensionPayloadBytes','indexedExtensions','indexSHA256','hostExecutableSHA256','certificateCategory','teamIdentifier','verifiedDesignatedRequirement','deepStrictSignatureVerified','dmgBytes','dmgSHA256','dmgURL','appcastSHA256','sparklePublicKey','sparkleEd25519Verified','notarization','publicationVerified','managedViewsVerified','hardwareVerified','sourceQualification','workflowSourceCommit','sourceMode'}
    require(set(value) == expected_keys, 'Unexpected host-proof fields')
    require(value['schema'] == 1 and type(value['schema']) is int and value['sourceCommit'] == value['workflowSourceCommit'] == source and value['sourceMode'] == 'current-workflow-source', 'Host proof differs from successful source or admits a rebuild')
    require(value['version'] == version and value['build'] == build and value['indexSHA256'] == index_sha256 and value['sparklePublicKey'] == sparkle_key, 'Host proof version or source resources differ')
    require(value['certificateCategory'] == certificate and certificate in ('Developer ID Application','Apple Development','Apple Distribution') and value['teamIdentifier'] == team and re.fullmatch('[A-Z0-9]{10}', team), 'Host signing identity differs')
    require(value['verifiedDesignatedRequirement'] == f'identifier "com.pulkit.edith" and anchor apple generic and certificate leaf[subject.OU] = "{team}"', 'Designated requirement differs')
    require(type(value['installedBytes']) is int and 0 < value['installedBytes'] < 10000000 and type(value['extensionPayloadBytes']) is int and value['extensionPayloadBytes'] == 0 and type(value['indexedExtensions']) is int and value['indexedExtensions'] == 39, 'Empty host size or index differs')
    require(re.fullmatch('[0-9a-f]{64}', value['hostExecutableSHA256']), 'Invalid host executable checksum')
    require(value['deepStrictSignatureVerified'] is True and value['sparkleEd25519Verified'] is True and value['publicationVerified'] is False and value['managedViewsVerified'] is False and value['hardwareVerified'] is False, 'Host proof tier claims differ')
    require(value['sourceQualification'] in ('clean','release-version-stamp-only') and value['notarization'] in ('verified','skipped'), 'Unknown host source or notarization qualification')
    require(file_hash(dmg) == {'bytes':value['dmgBytes'],'sha256':value['dmgSHA256']} and file_hash(appcast,1024**2)['sha256'] == value['appcastSHA256'], 'Host release artifact bytes differ')
    require(value['dmgURL'] == f'https://github.com/pulkitxm/edith/releases/download/v{version}/Edith.dmg', 'Host public DMG URL differs')
    return value


def parse_appcast(source_root, path, url, version, build, dmg_bytes):
    spec = importlib.util.spec_from_file_location('source_host_proof', Path(source_root)/'scripts/host_release_proof.py')
    module = importlib.util.module_from_spec(spec)
    import sys
    sys.path.insert(0, str(Path(source_root)/'scripts'))
    spec.loader.exec_module(module)
    with regular_file(path, 1024**2) as stream:
        data = stream.read(1024**2+1)
        require(len(data) <= 1024**2, 'Appcast grew beyond bound')
        signed = module.appcast_enclosure(data,url,version,build,dmg_bytes)
    return {'edSignature':signed,'appcastSHA256':hashlib.sha256(data).hexdigest(),'signatureVerified':False}


def extract_artifact(path, output, names):
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'hosted-managed-views'))
    spec = importlib.util.spec_from_file_location('public_archive_extractor', Path(__file__).resolve().parents[1] / 'hosted-managed-views/verify-package.py')
    extractor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(extractor)
    with regular_file(path, 2*1024**3):
        extractor.extract_regular(path, output, maximum_bytes=2*1024**3)
    actual = {file.relative_to(output).as_posix() for file in Path(output).rglob('*') if file.is_file()}
    require(actual == set(names), 'Artifact contains unknown or missing assets')
    for file in Path(output).rglob('*'):
        if file.is_file():
            file.chmod(0o600)
    return {'names': sorted(actual), 'zipCRCVerified': True}


def public_host(root, request_path):
    import sys
    sys.path.insert(0, str(Path(root) / 'scripts'))
    import host_release_proof as maintained
    values = document(request_path)
    proof = document(values['proof'])
    metadata = document(values['metadata'])
    source, tag = values['source'], values['tag']
    version, build = proof['version'], proof['build']
    def git(path):
        return subprocess.check_output(['git', '-C', root, 'show', source+':'+path], timeout=60)
    info = plistlib.loads(git('Resources/Info.plist'))
    index = git('Packages/EdithHost/Sources/EdithHostCore/Resources/index.json')
    host_proof(proof, source, version, build, hashlib.sha256(index).hexdigest(), info['SUPublicEDKey'], proof['teamIdentifier'], proof['certificateCategory'], values['dmg'], values['appcast'])
    require(metadata['sourceTreeDirty'] is (proof['sourceQualification'] == 'release-version-stamp-only'), 'Host source qualification differs')
    actual, sanitized = maintained.collect_proof(values['bundle'], values['dmg'], values['appcast'], metadata, info, index, source, tag, version, build, proof['notarization'])
    expected = {key: value for key, value in proof.items() if key not in ('sourceQualification','workflowSourceCommit','sourceMode')}
    require(actual == expected and sanitized == metadata, 'Actual public DMG host differs from source-bound CI host proof')
    return {'schema': 1, 'sourceCommit': source, 'hostExecutableSHA256': actual['hostExecutableSHA256'], 'installedBytes': actual['installedBytes'], 'dmgBytes': actual['dmgBytes'], 'dmgSHA256': actual['dmgSHA256'], 'appcastSHA256': actual['appcastSHA256'], 'teamIdentifier': actual['teamIdentifier'], 'certificateCategory': actual['certificateCategory'], 'notarization': actual['notarization'], 'sparkleEd25519Verified': True, 'extensionPayloadBytes': 0, 'indexedExtensions': 39, 'productExecuted': False}


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest='phase', required=True)
    doc = subparsers.add_parser('document')
    doc.add_argument('path')
    archive = subparsers.add_parser('archive')
    for name in ('path','identifier','bytes','sha256'):
        archive.add_argument(name)
    tag = subparsers.add_parser('tag')
    for name in ('root','source','tag','version','build','dmg_sha256'):
        tag.add_argument(name)
    extract = subparsers.add_parser('extract')
    for name in ('path','output'):
        extract.add_argument(name)
    extract.add_argument('names', nargs='+')
    host = subparsers.add_parser('host')
    host.add_argument('root')
    host.add_argument('request')
    args = parser.parse_args()
    if args.phase == 'document':
        result = document(args.path)
    elif args.phase == 'archive':
        result = archive_metrics(args.path,args.identifier,int(args.bytes),args.sha256)
    elif args.phase == 'extract':
        result = extract_artifact(args.path,args.output,args.names)
    elif args.phase == 'host':
        result = public_host(args.root,args.request)
    else:
        result = qualify_tag(args.root,args.source,args.tag,args.version,args.build,args.dmg_sha256)
    print(json.dumps(result,sort_keys=True))


if __name__ == '__main__':
    main()
