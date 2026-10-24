import argparse
import base64
import json
from pathlib import Path
import re
import stat

from host_release_proof import appcast_enclosure, closed_fields, digest, document, json_document, require, validate_metadata, validate_toolchain

ASSETS = ('Edith.dmg', 'appcast.xml', 'host-release-proof.json', 'build-metadata.json', 'toolchain-provenance.json')
PROOF_FIELDS = ('schema', 'sourceCommit', 'version', 'build', 'installedBytes', 'extensionPayloadBytes', 'indexedExtensions', 'indexSHA256', 'hostExecutableSHA256', 'certificateCategory', 'teamIdentifier', 'verifiedDesignatedRequirement', 'deepStrictSignatureVerified', 'dmgBytes', 'dmgSHA256', 'dmgURL', 'appcastSHA256', 'sparklePublicKey', 'sparkleEd25519Verified', 'notarization', 'publicationVerified', 'managedViewsVerified', 'hardwareVerified', 'sourceQualification', 'workflowSourceCommit', 'sourceMode')


def validate_assets(directory, repository, tag, source, rebuild=False):
    require(type(repository) is str and re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository) is not None, 'Invalid release repository')
    require(type(tag) is str and re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag) is not None, 'Invalid release tag')
    require(type(source) is str and re.fullmatch('[a-f0-9]{40}', source) is not None, 'Invalid release source')
    directory = Path(directory)
    for name in ASSETS:
        status = (directory / name).lstat()
        require(stat.S_ISREG(status.st_mode) and status.st_nlink == 1 and 0 < status.st_size <= (1024 ** 3 if name == 'Edith.dmg' else 1024 ** 2), 'Invalid bounded release asset')
    proof = json_document(directory / 'host-release-proof.json')
    metadata = json_document(directory / 'build-metadata.json')
    toolchain = json_document(directory / 'toolchain-provenance.json')
    closed_fields(proof, PROOF_FIELDS)
    validate_metadata(metadata)
    validate_toolchain(toolchain)
    require(type(proof['schema']) is int and proof['schema'] == 1, 'Invalid proof schema')
    for name in ('sourceCommit', 'workflowSourceCommit'):
        require(type(proof[name]) is str and re.fullmatch('[a-f0-9]{40}', proof[name]) is not None, 'Invalid proof source')
    for name in ('hostExecutableSHA256', 'indexSHA256', 'dmgSHA256', 'appcastSHA256'):
        require(type(proof[name]) is str and re.fullmatch('[a-f0-9]{64}', proof[name]) is not None, 'Invalid proof hash')
    require(proof['sourceCommit'] == metadata['sourceCommit'] == toolchain['sourceCommit'] == source, 'Release source differs between receipts')
    require(proof['hostExecutableSHA256'] == metadata['hostExecutableSHA256'] == toolchain['hostExecutableSHA256'], 'Shipping executable differs between receipts')
    require(proof['sourceMode'] == ('tag-rebuild' if rebuild else 'current-workflow-source'), 'Proof source mode differs')
    require(rebuild or proof['workflowSourceCommit'] == source, 'Workflow source differs from built source')
    require(proof['sourceQualification'] == ('release-version-stamp-only' if metadata['sourceTreeDirty'] else 'clean'), 'Proof source qualification differs')
    require(proof['version'] == tag[1:] and type(proof['build']) is str and re.fullmatch('[0-9]+', proof['build']) is not None and len(proof['build']) <= 32, 'Proof version or build differs')
    for name, minimum, maximum in [('installedBytes', 1, 9999999), ('extensionPayloadBytes', 0, 0), ('indexedExtensions', 40, 40), ('dmgBytes', 1, 1024 ** 3)]:
        require(type(proof[name]) is int and minimum <= proof[name] <= maximum, 'Invalid proof byte count or extension inventory')
    require(proof['deepStrictSignatureVerified'] is True and proof['sparkleEd25519Verified'] is True, 'Missing shipping signature qualification')
    require(all(proof[name] is False for name in ('publicationVerified', 'managedViewsVerified', 'hardwareVerified')), 'Static proof claims runtime qualification')
    require(proof['certificateCategory'] in ('Developer ID Application', 'Apple Development', 'Apple Distribution') and proof['notarization'] in ('verified', 'skipped'), 'Invalid shipping signature or notarization category')
    require(type(proof['teamIdentifier']) is str and re.fullmatch('[A-Z0-9]{10}', proof['teamIdentifier']) is not None, 'Invalid signing team')
    requirement = f'identifier "com.pulkit.edith" and anchor apple generic and certificate leaf[subject.OU] = "{proof["teamIdentifier"]}"'
    require(proof['verifiedDesignatedRequirement'] == requirement, 'Shipping designated requirement differs')
    key = proof['sparklePublicKey']
    require(type(key) is str and len(key) == 44 and len(base64.b64decode(key, validate=True)) == 32, 'Invalid qualified Sparkle key')
    url = f'https://github.com/{repository}/releases/download/{tag}/Edith.dmg'
    dmg = directory / 'Edith.dmg'
    require(proof['dmgURL'] == url and proof['dmgBytes'] == dmg.stat().st_size and proof['dmgSHA256'] == digest(dmg), 'DMG differs from qualified proof')
    appcast = document(directory / 'appcast.xml')
    require(proof['appcastSHA256'] == digest(directory / 'appcast.xml'), 'Appcast differs from qualified proof')
    appcast_enclosure(appcast, url, proof['version'], proof['build'], proof['dmgBytes'])
    return ASSETS


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--source', required=True)
    parser.add_argument('--rebuild', action='store_true')
    args = parser.parse_args()
    validate_assets(args.directory, args.repository, args.tag, args.source, args.rebuild)
    proof = json_document(args.directory / 'host-release-proof.json')
    signature = appcast_enclosure(document(args.directory / 'appcast.xml'), proof['dmgURL'], proof['version'], proof['build'], proof['dmgBytes'])
    print(json.dumps({'sparklePublicKey': proof['sparklePublicKey'], 'sparkleSignature': signature}))


if __name__ == '__main__':
    main()
