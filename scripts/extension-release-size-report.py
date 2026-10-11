import argparse
from contextlib import contextmanager
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import re
import subprocess
import tempfile

import host_release_proof
from macho_code_identity import executable_identity
from size_report_filesystem import TreeSnapshot, digest_file, read_bytes
from verify_shipping_host import inspect_layout


def load_report_module():
    spec = importlib.util.spec_from_file_location('host_sizes', Path(__file__).with_name('extension-host-size-report.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@contextmanager
def source_directory(root):
    previous = Path.cwd()
    os.chdir(root)
    try:
        yield
    finally:
        os.chdir(previous)


def qualify_release(bundle, dmg, appcast, metadata, source_root, source, tag, version, build, notary):
    with source_directory(source_root):
        qualification = host_release_proof.qualify_source(source, tag, os.environ)
        info, index, dirty = host_release_proof.pinned_sources(source, version, build)
        if metadata.get('sourceTreeDirty') is not dirty:
            raise ValueError('Shipping metadata differs from maintained source qualification')
        proof, preserved = host_release_proof.collect_proof(
            bundle, dmg, appcast, metadata, info, index, source, tag, version, build, notary,
            layout=lambda app, **keywords: inspect_layout(app, release=True, launcher_required=False))
    proof.update(qualification)
    proof['sourceQualification'] = 'release-version-stamp-only' if dirty else 'clean'
    return proof, preserved


def verify_catalog(catalog, pointer, key):
    script = '''import {readFile} from 'node:fs/promises';
import {verifiedCatalogPayload} from './scripts/verify-extension-catalog.mjs';
import {parseCatalogPointer,verifyCatalogPointerData} from './scripts/extension-catalog-pointer.mjs';
const [catalog,pointer,key] = process.argv.slice(1);
const data = await readFile(catalog);
import {basename} from 'node:path';
const pin = parseCatalogPointer(await readFile(pointer,'utf8'));
if (pin.assetName !== basename(catalog)) throw new Error('Catalog filename differs');
verifyCatalogPointerData(data,pin);
const payload = JSON.parse(verifiedCatalogPayload(data,key));
if (payload.revision !== pin.revision) throw new Error('Catalog revision differs');
process.stdout.write(JSON.stringify(payload));'''
    result = subprocess.run(['node', '--input-type=module', '-e', script, str(catalog), str(pointer), key],
                            check=True, capture_output=True, text=True, timeout=60)
    return json.loads(result.stdout)


def verify_dmg_app(dmg, shipping_app):
    host = load_report_module()
    with tempfile.TemporaryDirectory(prefix='release-size-dmg-') as temporary:
        mount = Path(temporary) / 'mounted'
        mount.mkdir()
        subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
                        '-mountpoint', str(mount), str(dmg)], check=True, capture_output=True, timeout=60)
        try:
            if {path.name for path in mount.iterdir()} != {'Edith.app', 'Applications'}:
                raise ValueError('Unexpected shipping DMG inventory')
            if not (mount / 'Applications').is_symlink() or os.readlink(mount / 'Applications') != '/Applications':
                raise ValueError('Invalid shipping DMG application link')
            if host.tree_inventory(mount / 'Edith.app') != host.tree_inventory(shipping_app):
                raise ValueError('DMG app differs from independently qualified signed shipping app')
        finally:
            subprocess.run(['hdiutil', 'detach', str(mount)], check=True, capture_output=True, timeout=60)
    return True


def validate_toolchain_receipt(receipt, source, executable_hash, metadata):
    if (not isinstance(receipt, dict) or set(receipt) != {'schema', 'sourceCommit', 'hostExecutableSHA256', 'xcode', 'sdk', 'builderSignature'}
            or type(receipt['schema']) is not int or receipt['schema'] != 1
            or receipt['sourceCommit'] != source or receipt['hostExecutableSHA256'] != executable_hash
            or not isinstance(receipt['xcode'], str) or len(receipt['xcode']) > 256
            or not re.fullmatch(r'Xcode [0-9]+\.[0-9]+(?:\.[0-9]+)?\nBuild version [A-Za-z0-9]+', receipt['xcode'])
            or not isinstance(receipt['sdk'], str) or len(receipt['sdk']) > 32
            or not re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', receipt['sdk'])
            or receipt['builderSignature'] not in {'ad-hoc', 'unsigned'}):
        raise ValueError('Invalid closed-schema toolchain receipt')
    if any(field in metadata and metadata[field] != receipt[field] for field in ['xcode', 'sdk']):
        raise ValueError('Toolchain receipt differs from existing build metadata')
    return receipt


def aggregate_release(frozen, shipping_app, shipping_metadata, assets, catalog_name, pointer_name,
                      catalog_key, toolchain_receipt, *, qualify, catalog_verify=verify_catalog, code_identity=executable_identity, dmg_verify=verify_dmg_app):
    host = load_report_module()
    source = frozen['measurement']['expectedSourceCommit']
    host.validate_final_source(source, frozen['measurement']['currentSource'], frozen['measurement']['hostBuild'])
    if (frozen['measurement'].get('sourceMode') != 'final'
            or frozen['measurement'].get('carrierHostProvenanceVerified') is not True
            or frozen['measurement'].get('sourceFingerprintsVerified') is not True
            or frozen.get('indexedExtensions') != 39 or frozen.get('migratedExtensions') != 39
            or frozen.get('unmeasuredExtensions') != []):
        raise ValueError('Aggregate requires freshly verified clean frozen host and all39 packages')
    identifiers = {package['id'] for package in frozen['packages']}
    if (len(identifiers) != 39 or identifiers != set(frozen['sourceFingerprints'])
            or identifiers != set(frozen['packageHostProvenance'])
            or any(package.get('sourceFingerprint') != frozen['sourceFingerprints'][package['id']]
                   for package in frozen['packages'])):
        raise ValueError('Frozen package fingerprint and provenance inventory differs')
    shipping_app, assets = Path(shipping_app).absolute(), Path(assets).absolute()
    app_snapshot, asset_snapshot = TreeSnapshot(shipping_app), TreeSnapshot(assets)
    if not re.fullmatch(r'catalog-[1-9][0-9]*\.json', catalog_name or ''):
        raise ValueError('Expected immutable signed catalog filename')
    if pointer_name != Path(pointer_name).name or pointer_name in {'Edith.dmg', 'appcast.xml', catalog_name}:
        raise ValueError('Invalid catalog pointer filename')
    allowed = {'Edith.dmg': 'shippingDMG', 'appcast.xml': 'signedAppcast',
               catalog_name: 'signedCatalog', pointer_name: 'catalogPointer'}
    for name in list(allowed):
        allowed[name + '.sha256'] = 'detachedChecksums'
    measured_assets = []
    asset_files = set(asset_snapshot.files)
    for path in asset_snapshot.entries:
        if path == assets:
            continue
        name = path.relative_to(assets).as_posix()
        if name not in allowed or path not in asset_files:
            raise ValueError('Unexpected final release asset inventory entry')
        measured_assets.append({'name': name, 'category': allowed[name],
                                'bytes': path.stat().st_size, 'sha256': digest_file(path)})
    by_name = {asset['name']: asset for asset in measured_assets}
    if not {'Edith.dmg', 'appcast.xml', catalog_name, pointer_name}.issubset(by_name):
        raise ValueError('Missing final release asset')
    for name in by_name:
        if name.endswith('.sha256'):
            original = name.removesuffix('.sha256')
            if read_bytes(assets / name) != f"{by_name[original]['sha256']}  {original}\n".encode():
                raise ValueError('Final detached checksum differs')
    proof, preserved = qualify(shipping_app, assets / 'Edith.dmg', assets / 'appcast.xml', shipping_metadata)
    expected_dirty = proof.get('sourceQualification') == 'release-version-stamp-only'
    if (proof.get('schema') != 1 or proof.get('sourceQualification') not in {'clean', 'release-version-stamp-only'}
            or proof.get('sourceCommit') != source or shipping_metadata.get('sourceCommit') != source
            or shipping_metadata.get('sourceTreeDirty') is not expected_dirty
            or proof.get('deepStrictSignatureVerified') is not True or proof.get('sparkleEd25519Verified') is not True
            or proof.get('indexedExtensions') != 39 or proof.get('extensionPayloadBytes') != 0
            or proof.get('dmgSHA256') != by_name['Edith.dmg']['sha256']
            or proof.get('dmgBytes') != by_name['Edith.dmg']['bytes']
            or proof.get('appcastSHA256') != by_name['appcast.xml']['sha256']):
        raise ValueError('Independently qualified shipping release differs from measured artifacts')
    shipping_hash = digest_file(shipping_app / 'Contents/MacOS/Edith')
    toolchain = validate_toolchain_receipt(toolchain_receipt, source, shipping_hash, shipping_metadata)
    shipping_code = code_identity(shipping_app / 'Contents/MacOS/Edith')
    if (shipping_hash != proof.get('hostExecutableSHA256')
            or shipping_hash != shipping_metadata.get('hostExecutableSHA256')
            or shipping_code['signedSHA256'] != shipping_hash
            or shipping_code['normalizedUnsignedSHA256'] != frozen['hostCodeIdentity']['normalizedUnsignedSHA256']):
        raise ValueError('Shipping code differs from exact clean frozen package host')
    shipping_info = plistlib.loads(read_bytes(shipping_app / 'Contents/Info.plist'))
    expected_info = {**frozen['hostInfo'], 'CFBundleShortVersionString': proof['version'], 'CFBundleVersion': proof['build']}
    if shipping_info != expected_info:
        raise ValueError('Shipping plist changed beyond qualified release version stamp')
    shipping_inventory = host.tree_inventory(shipping_app)
    frozen_inventory = frozen['hostTreeInventory']
    allowed_changes = {'Contents/Info.plist', 'Contents/MacOS/Edith'}
    def resources(inventory):
        return {name: entry for name, entry in inventory.items()
                if name not in allowed_changes and '_CodeSignature' not in Path(name).parts}
    frozen_resources, shipping_resources = resources(frozen_inventory), resources(shipping_inventory)
    if set(frozen_resources) != set(shipping_resources):
        raise ValueError('Shipping resources differ from frozen package host')
    resource_code = {}
    for name, entry in shipping_resources.items():
        if entry != frozen_resources[name]:
            expected = frozen.get('resourceCodeIdentities', {}).get(name)
            if not expected or 'sha256' not in entry:
                raise ValueError('Shipping resources differ from frozen package host')
            actual = code_identity(shipping_app / name, filetype=expected['filetype'])
            if actual['normalizedUnsignedSHA256'] != expected['normalizedUnsignedSHA256']:
                raise ValueError('Shipping resource code differs from frozen package host')
            resource_code[name] = actual
    installed = sum(app_snapshot.entries[path][3] for path in app_snapshot.files)
    if installed != proof.get('installedBytes'):
        raise ValueError('Qualified shipping app logical bytes differ')
    index_hash = digest_file(shipping_app / 'Contents/Resources/index.json')
    if index_hash != proof.get('indexSHA256'):
        raise ValueError('Qualified shipping index differs')
    catalog = catalog_verify(assets / catalog_name, assets / pointer_name, catalog_key)
    catalog_packages = {package['id']: package for package in catalog['packages']}
    if len(catalog_packages) != len(catalog['packages']) or set(catalog_packages) != identifiers:
        raise ValueError('Signed catalog must contain exactly current39 packages')
    for package in frozen['packages']:
        row = catalog_packages[package['id']]
        for field in ['id', 'version', 'downloadBytes', 'installedBytes', 'sha256', 'sourceFingerprint',
                      'hostABI', 'architecture', 'dependencies', 'minimumSystemVersion', 'downloadURL']:
            if row.get(field) != package.get(field):
                raise ValueError('Signed catalog differs from exact frozen package metadata')
        provenance = frozen['packageHostProvenance'][package['id']]
        if row.get('minimumSystemVersion') != provenance.get('minimumSystemVersion'):
            raise ValueError('Signed catalog minimum system version differs')
    if dmg_verify(assets / 'Edith.dmg', shipping_app) is not True:
        raise ValueError('DMG signed app binding was not verified')
    totals = {}
    for asset in frozen['releaseArtifactInventory'] + measured_assets:
        category = asset['category']
        totals[category] = totals.get(category, 0) + asset['bytes']
    app_snapshot.verify()
    asset_snapshot.verify()
    return {'schema': 1, 'status': 'qualified-final-local-artifacts', 'artifactPublication': 'not-verified',
            'current39Source': frozen['measurement']['currentSource'], 'sourceFingerprints': frozen['sourceFingerprints'],
            'frozenPackageHost': frozen, 'signedShippingHost': {'releaseProof': proof, 'buildMetadata': preserved,
                'toolchainReceipt': toolchain, 'toolchainProvenance': 'Recorded bounded builder receipt tied to source and signed shipping executable; builderSignature describes build signing, while releaseProof independently verifies the final certificate and signature.',
                'installedLogicalBytes': installed, 'codeIdentity': shipping_code, 'treeInventory': shipping_inventory,
                'resourceCodeIdentities': resource_code, 'dmgContainedAppVerified': True},
            'releaseAssets': sorted(measured_assets, key=lambda asset: asset['name']),
            'releaseAssetBytesByCategory': totals, 'scopedReleaseAssetBytes': sum(totals.values()),
            'shippingAppPlusAll39LogicalBytes': installed + sum(package['installedBytes'] for package in frozen['packages']),
            'shippingDMGPlusAll39ZIPBytes': by_name['Edith.dmg']['bytes'] + sum(package['downloadBytes'] for package in frozen['packages']),
            'measurement': {'installedMethod': 'Actual logical regular-file bytes, including packaged models and every copied executable/framework once. No duplicate-byte deductions.',
                'compressedMethod': 'Actual signed shipping DMG and package ZIP bytes. Frozen host comparison ZIP remains a separate comparison metric.',
                'releaseAssetsScope': 'One current shipping DMG, signed appcast, current39 ZIPs and metadata, allowed provenance receipts, supplied detached checksums, one verified signed catalog and pointer. Excludes older releases and proof/report documents.',
                'codeRelationship': 'Exact normalized unsigned arm64 host code equality; unchanged frozen resources except release Info.plist and code-signature records. Source stamping is independently qualified by maintained host_release_proof.',
                'limitations': 'Local artifact qualification does not establish remote publication, lifecycle, visual, hardware or managed-view verification.'}}


def main():
    parser = argparse.ArgumentParser()
    for name in ['baseline', 'frozen-app', 'frozen-build', 'packages', 'shipping-app', 'shipping-build',
                 'source-root', 'release-source-root', 'assets', 'toolchain-receipt', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ['source', 'tag', 'version', 'build', 'catalog-name', 'pointer-name']:
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--notarization', choices=['verified', 'skipped'], required=True)
    args = parser.parse_args()
    for name in ['baseline', 'frozen_app', 'frozen_build', 'packages', 'shipping_app', 'shipping_build',
                 'source_root', 'release_source_root', 'assets', 'toolchain_receipt', 'output']:
        setattr(args, name, getattr(args, name).absolute())
    host = load_report_module()
    frozen_snapshot, packages_snapshot = TreeSnapshot(args.frozen_app), TreeSnapshot(args.packages)
    documents = {path: digest_file(path) for path in [args.baseline, args.frozen_build, args.shipping_build, args.toolchain_receipt]}
    with source_directory(args.source_root):
        current = host.read_source_state(Path.cwd())
        metadata = json.loads(read_bytes(args.frozen_build))
        host.validate_final_source(args.source, current, metadata)
        definitions = json.loads(read_bytes(Path('Extensions/manifest.json')))
        index = json.loads(read_bytes(Path('Packages/EdithHost/Sources/EdithHostCore/Resources/index.json')))
        fingerprints = json.loads(subprocess.run(['bun', 'scripts/extension-artifact-fingerprints.mjs'],
            check=True, capture_output=True, text=True).stdout)
        frozen = host.build_report(json.loads(read_bytes(args.baseline)), args.frozen_app, args.packages,
            definitions, index, fingerprints, metadata, expected_source_commit=args.source, source_state=current)
        key_source = read_bytes(Path('Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift')).decode()
        matches = re.findall(r'base64Encoded: "([A-Za-z0-9+/=]+)"', key_source)
        if len(matches) != 1:
            raise ValueError('Pinned catalog key is ambiguous')
        result = aggregate_release(frozen, args.shipping_app, json.loads(read_bytes(args.shipping_build)),
            args.assets, args.catalog_name, args.pointer_name, matches[0], json.loads(read_bytes(args.toolchain_receipt)),
            qualify=lambda app, dmg, appcast, built: qualify_release(app, dmg, appcast, built,
                args.release_source_root, args.source, args.tag, args.version, args.build, args.notarization))
        frozen_snapshot.verify()
        packages_snapshot.verify()
        if any(digest_file(path) != expected for path, expected in documents.items()):
            raise ValueError('Final aggregate input document changed')
        result['signedShippingHost']['toolchainReceiptSHA256'] = documents[args.toolchain_receipt]
        host.validate_final_source(args.source, host.read_source_state(Path.cwd()), metadata)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
