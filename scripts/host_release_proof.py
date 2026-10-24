import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from verify_shipping_host import inspect_layout

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
METADATA_FIELDS = ('sourceCommit', 'sourceTreeDirty', 'configuration', 'optimization', 'linkTimeOptimization', 'architecture', 'hostExecutableSHA256')
TOOLCHAIN_FIELDS = ('schema', 'sourceCommit', 'hostExecutableSHA256', 'xcode', 'sdk', 'builderSignature')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def document(path, maximum=1024 * 1024):
    path = Path(path)
    status = path.lstat()
    require(stat.S_ISREG(status.st_mode) and status.st_nlink == 1 and 0 < status.st_size <= maximum, 'Invalid bounded regular document')
    return path.read_bytes()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate document field')
        result[key] = value
    return result


def json_document(path):
    return json.loads(document(path), object_pairs_hook=unique_object)


def closed_fields(value, fields):
    require(type(value) is dict and set(value) == set(fields), 'Unexpected document fields')


def validate_metadata(metadata):
    closed_fields(metadata, METADATA_FIELDS)
    require(type(metadata['sourceCommit']) is str and re.fullmatch('[a-f0-9]{40}', metadata['sourceCommit']) is not None, 'Invalid metadata source')
    require(type(metadata['hostExecutableSHA256']) is str and re.fullmatch('[a-f0-9]{64}', metadata['hostExecutableSHA256']) is not None, 'Invalid metadata executable hash')
    require(type(metadata['sourceTreeDirty']) is bool, 'Invalid metadata source state')
    require(metadata['configuration'] == 'Release' and metadata['optimization'] == 'Osize' and metadata['linkTimeOptimization'] == 'full' and metadata['architecture'] == 'arm64', 'Unexpected host build configuration')


def validate_toolchain(receipt):
    closed_fields(receipt, TOOLCHAIN_FIELDS)
    require(type(receipt['schema']) is int and receipt['schema'] == 1, 'Invalid toolchain schema')
    for name, size in [('sourceCommit', 40), ('hostExecutableSHA256', 64)]:
        require(type(receipt[name]) is str and re.fullmatch('[a-f0-9]{' + str(size) + '}', receipt[name]) is not None, 'Invalid toolchain source or hash')
    for name, maximum, pattern in [('xcode', 256, r'Xcode [0-9]+\.[0-9]+(?:\.[0-9]+)?\nBuild version [A-Za-z0-9]+'), ('sdk', 32, r'[0-9]+\.[0-9]+(?:\.[0-9]+)?')]:
        require(type(receipt[name]) is str and len(receipt[name]) <= maximum and re.fullmatch(pattern, receipt[name]) is not None, 'Invalid measured toolchain field')
    require(type(receipt['builderSignature']) is str and receipt['builderSignature'] in ('ad-hoc', 'unsigned'), 'Invalid builder signature')


def collect_toolchain(builder, proof, sanitized):
    closed_fields(builder, (*METADATA_FIELDS, 'xcode', 'sdk', 'signature'))
    validate_metadata({name: builder[name] for name in METADATA_FIELDS})
    validate_metadata(sanitized)
    require(all(builder[name] == sanitized[name] for name in METADATA_FIELDS if name != 'hostExecutableSHA256'), 'Builder metadata differs from shipping source or configuration')
    require(proof['sourceCommit'] == sanitized['sourceCommit'] and proof['hostExecutableSHA256'] == sanitized['hostExecutableSHA256'], 'Qualified shipping executable differs')
    receipt = {'schema': 1, 'sourceCommit': proof['sourceCommit'], 'hostExecutableSHA256': proof['hostExecutableSHA256'], 'xcode': builder['xcode'], 'sdk': builder['sdk'], 'builderSignature': builder['signature']}
    validate_toolchain(receipt)
    return receipt


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def command(arguments):
    result = subprocess.run(arguments, check=True, capture_output=True, timeout=60)
    require(len(result.stdout) + len(result.stderr) <= 1024 * 1024, 'Command output exceeds its bound')
    return (result.stdout + result.stderr).decode()


def appcast_enclosure(data, url, version, build, length):
    require(len(data) <= 1024 * 1024 and b'<!DOCTYPE' not in data.upper() and b'<!ENTITY' not in data.upper(), 'Invalid appcast document')
    feed = ET.fromstring(data)
    require(feed.tag == 'rss', 'Invalid appcast root')
    items = feed.findall('./channel/item')
    enclosures = feed.findall('.//enclosure')
    require(len(items) == 1 and len(enclosures) == 1 and items[0].find('enclosure') is enclosures[0], 'Expected exactly one appcast item and enclosure')
    item, enclosure = items[0], enclosures[0]
    for name, expected in [('version', build), ('shortVersionString', version)]:
        values = item.findall(SPARKLE + name)
        require(len(values) == 1 and values[0].text == expected, 'Appcast version or build differs')
    require(enclosure.get('url') == url and enclosure.get('length') == str(length), 'Appcast URL or length differs')
    signature = enclosure.get(SPARKLE + 'edSignature', '')
    require(len(base64.b64decode(signature, validate=True)) == 64, 'Invalid Sparkle signature encoding')
    return signature


def verify_signature(key, signature, dmg):
    with tempfile.TemporaryDirectory(prefix='host-release-signature-') as temporary:
        executable = Path(temporary) / 'verify-signature'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-O', str(Path(__file__).with_name('verify-host-release-signature.swift')), '-o', str(executable)], check=True, capture_output=True, timeout=180)
        subprocess.run([str(executable), key, signature, str(dmg)], check=True, capture_output=True, timeout=60)


def collect_proof(bundle, dmg, appcast, metadata, pinned_info, expected_index, source, tag, version, build, notary, *, run=command, layout=inspect_layout, signature=verify_signature):
    require(re.fullmatch('[a-f0-9]{40}', source) is not None, 'Invalid source commit')
    require(re.fullmatch(r'v\d+\.\d+\.\d+', tag) is not None and tag == 'v' + version, 'Invalid release tag')
    require(re.fullmatch(r'\d+', build) is not None and notary in ('verified', 'skipped'), 'Invalid release build or notarization state')
    bundle, dmg = Path(bundle), Path(dmg)
    info = layout(bundle, release=True, launcher_required=True)
    require(info['CFBundleShortVersionString'] == version and str(info['CFBundleVersion']) == build, 'Host version or build differs')
    key = info['SUPublicEDKey']
    require(key == pinned_info['SUPublicEDKey'] and len(base64.b64decode(key, validate=True)) == 32, 'Host Sparkle key differs from pinned source')
    index_bytes = document(bundle / 'Contents/Resources/index.json')
    require(index_bytes == expected_index, 'Host index differs from pinned source')
    index = json.loads(index_bytes)
    require(len(index) == 40 and len({row['id'] for row in index}) == 40, 'Expected exactly39 indexed extensions')
    installed = 0
    for path in bundle.rglob('*'):
        status = path.lstat()
        if stat.S_ISLNK(status.st_mode):
            require(path.resolve().is_relative_to(bundle.resolve()) and path.resolve().exists(), 'Host link escapes bundle')
        elif stat.S_ISREG(status.st_mode):
            installed += status.st_size
        else:
            require(stat.S_ISDIR(status.st_mode), 'Host contains a special file')
        require(path.suffix not in ('.appex', '.bundle') or path == bundle / 'Contents/Resources/EdithHost_EdithHost.bundle', 'Feature payload in host')
    require(0 < installed < 10000000, 'Empty host exceeds size limit')
    executable_hash = digest(bundle / 'Contents/MacOS/Edith')
    require(metadata['sourceCommit'] == source and metadata['hostExecutableSHA256'] == executable_hash, 'Host metadata source or executable differs')
    require(metadata['configuration'] == 'Release' and metadata['optimization'] == 'Osize' and metadata['linkTimeOptimization'] == 'full' and metadata['architecture'] == 'arm64', 'Unexpected host build configuration')
    run(['codesign', '--verify', '--deep', '--strict', str(bundle)])
    details = run(['codesign', '-dv', '--verbose=4', str(bundle)])
    teams = re.findall(r'^TeamIdentifier=([A-Z0-9]{10})$', details, re.M)
    require(len(teams) == 1, 'Missing Apple signing team')
    categories = [category for category in ('Developer ID Application', 'Apple Development', 'Apple Distribution') if re.search(r'^Authority=' + re.escape(category) + r':', details, re.M)]
    require(len(categories) == 1, 'Unsupported or unsigned certificate category')
    requirement = f'identifier "com.pulkit.edith" and anchor apple generic and certificate leaf[subject.OU] = "{teams[0]}"'
    designated = run(['codesign', '-d', '-r-', str(bundle)])
    rendered = re.findall(r'^designated => (.+)$', designated, re.M)
    unquoted = requirement.replace(f'"{teams[0]}"', teams[0])
    require(rendered in ([requirement], [unquoted]), 'Host designated requirement differs')
    run(['codesign', '--verify', '--strict', '-R=' + requirement, str(bundle)])
    dmg_status = dmg.lstat()
    require(stat.S_ISREG(dmg_status.st_mode) and dmg_status.st_nlink == 1 and 0 < dmg_status.st_size <= 1024 ** 3, 'Invalid DMG file')
    dmg_hash = digest(dmg)
    url = f'https://github.com/pulkitxm/edith/releases/download/{tag}/Edith.dmg'
    appcast_bytes = document(appcast)
    signed = appcast_enclosure(appcast_bytes, url, version, build, dmg_status.st_size)
    signature(key, signed, dmg)
    require(digest(dmg) == dmg_hash and dmg.stat().st_size == dmg_status.st_size, 'DMG changed during signature verification')
    if notary == 'verified':
        run(['xcrun', 'stapler', 'validate', str(dmg)])
        run(['spctl', '-a', '-t', 'open', '--context', 'context:primary-signature', str(dmg)])
    require(digest(bundle / 'Contents/MacOS/Edith') == executable_hash, 'Shipping executable changed during qualification')
    sanitized = {name: metadata[name] for name in METADATA_FIELDS}
    validate_metadata(sanitized)
    return {'schema': 1, 'sourceCommit': source, 'version': version, 'build': build, 'installedBytes': installed, 'extensionPayloadBytes': 0, 'indexedExtensions': 40, 'indexSHA256': hashlib.sha256(index_bytes).hexdigest(), 'hostExecutableSHA256': executable_hash, 'certificateCategory': categories[0], 'teamIdentifier': teams[0], 'verifiedDesignatedRequirement': requirement, 'deepStrictSignatureVerified': True, 'dmgBytes': dmg_status.st_size, 'dmgSHA256': dmg_hash, 'dmgURL': url, 'appcastSHA256': hashlib.sha256(appcast_bytes).hexdigest(), 'sparklePublicKey': key, 'sparkleEd25519Verified': True, 'notarization': notary, 'publicationVerified': False, 'managedViewsVerified': False, 'hardwareVerified': False}, sanitized


def pinned_sources(source, version, build, run=command):
    require(run(['git', 'rev-parse', 'HEAD']).strip() == source, 'Checkout source differs')
    require(not run(['git', 'ls-files', '--others', '--exclude-standard', '-z']), 'Untracked source inputs cannot qualify a host release')
    require(not run(['git', 'ls-files', '--others', '-z', '--', 'Packages/EdithHost/Sources', 'Packages/ExtensionMarketplace/Sources', 'Packages/ExtensionSupport/Sources', 'Extensions/fixtureSupport', ':(glob,exclude)**/.build/**', ':(glob,exclude)**/.swiftpm/**', ':(glob,exclude)**/.DS_Store']), 'Ignored untracked source inputs cannot qualify a host release')
    paths = run(['git', 'diff', '--name-only', 'HEAD']).splitlines()
    require(set(paths) <= {'Resources/Info.plist', 'Resources/HelperInfo.plist'}, 'Unexpected source changes')
    for path in paths:
        original = plistlib.loads(subprocess.check_output(['git', 'show', f'{source}:{path}']))
        original.update(CFBundleShortVersionString=version, CFBundleVersion=build)
        require(plistlib.loads(document(path)) == original, 'Source has changes beyond release version stamping')
    info = plistlib.loads(subprocess.check_output(['git', 'show', f'{source}:Resources/Info.plist']))
    index = subprocess.check_output(['git', 'show', f'{source}:Packages/EdithHost/Sources/EdithHostCore/Resources/index.json'])
    definitions = json.loads(subprocess.check_output(['git', 'show', f'{source}:Extensions/manifest.json']))
    ids = [row['id'] for row in definitions]
    require(len(ids) == 40 and len(set(ids)) == 40 and sorted(ids) == sorted(row['id'] for row in json.loads(index)), 'Pinned source index differs from39-owner manifest')
    return info, index, bool(paths)


def qualify_source(source, tag, environment, run=command):
    workflow = environment.get('GITHUB_SHA', '')
    rebuild = environment.get('REBUILD', '')
    require(re.fullmatch('[a-f0-9]{40}', workflow) is not None, 'Invalid workflow source')
    if rebuild:
        require(rebuild == tag and run(['git', 'rev-parse', f'refs/tags/{tag}^{{commit}}']).strip() == source, 'Rebuild tag source differs')
    else:
        require(workflow == source, 'Workflow source differs')
    return {'workflowSourceCommit': workflow, 'sourceMode': 'tag-rebuild' if rebuild else 'current-workflow-source'}


def main():
    parser = argparse.ArgumentParser()
    for name in ('bundle', 'dmg', 'appcast', 'output'):
        parser.add_argument(name, type=Path)
    parser.add_argument('--builder-metadata', type=Path, default=Path('local/minimal-host/build-metadata.json'))
    parser.add_argument('--source', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--notarization', choices=('verified', 'skipped'), required=True)
    args = parser.parse_args()
    qualification = qualify_source(args.source, args.tag, os.environ)
    info, index, dirty = pinned_sources(args.source, args.version, args.build)
    metadata = json_document(args.bundle.parent / 'build-metadata.json')
    builder = json_document(args.builder_metadata)
    require(all(metadata.get(name) == builder.get(name) for name in ('xcode', 'sdk')), 'Shipping toolchain differs from measured builder metadata')
    require(metadata['sourceTreeDirty'] is dirty, 'Build metadata source state differs')
    proof, sanitized = collect_proof(args.bundle, args.dmg, args.appcast, metadata, info, index, args.source, args.tag, args.version, args.build, args.notarization)
    proof['sourceQualification'] = 'release-version-stamp-only' if dirty else 'clean'
    proof.update(qualification)
    toolchain = collect_toolchain(builder, proof, sanitized)
    args.output.mkdir(mode=0o700)
    for name, value in [('host-release-proof.json', proof), ('build-metadata.json', sanitized), ('toolchain-provenance.json', toolchain)]:
        with (args.output / name).open('x') as target:
            target.write(json.dumps(value, indent=2) + '\n')


if __name__ == '__main__':
    main()
