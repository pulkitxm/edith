import hashlib
import json
import plistlib
import stat
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from macho_code_identity import executable_identity
from package_extension_lifecycle_tools import carrier_input


def resources(root):
    root = Path(root)
    if not root.is_dir() or root.is_symlink() or root.resolve() != root.absolute():
        raise ValueError('Host resources require a canonical regular bundle')
    entries = sorted(root.rglob('*'))
    if len(entries) > 10000:
        raise ValueError('Host resource inventory exceeds its bound')
    result, total = {}, 0
    for path in entries:
        status = path.lstat()
        if stat.S_ISDIR(status.st_mode):
            continue
        if not stat.S_ISREG(status.st_mode) or path.is_symlink():
            raise ValueError('Host resource inventory contains a nonregular file')
        total += status.st_size
        if total > 16 * 1024**2:
            raise ValueError('Host resource bytes exceed their bound')
        result[path.relative_to(root).as_posix()] = {'bytes': status.st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'mode': stat.S_IMODE(status.st_mode)}
    if not result:
        raise ValueError('Host resources are missing')
    return result


def plist(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
        raise ValueError('Host carrier metadata is not a bounded regular file')
    return plistlib.loads(path.read_bytes())


def worker_entitlements(worker):
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(worker)], check=True, capture_output=True, timeout=30)
    return plistlib.loads(result.stdout)


def fixture_host_inventory(host, payload, metadata, *, identity=executable_identity, verify=None, entitlements=worker_entitlements):
    host, payload = Path(host), Path(payload)
    for path in (host, payload):
        if path.is_symlink() or not path.is_dir() or path.resolve() != path.absolute():
            raise ValueError('Host inventory requires canonical bundle boundaries')
    if verify is None:
        verify = lambda path: subprocess.run(['codesign', '--verify', '--deep', '--strict', str(path)], check=True, capture_output=True, timeout=60)
    identifier, owner = metadata['hostIdentifier'], metadata['extensionID']
    prefix = 'com.pulkit.edith.tests.' + ('remote-' if owner == 'calendar' else 'worker-')
    import uuid
    if not identifier.startswith(prefix) or str(uuid.UUID(identifier.removeprefix(prefix))) != identifier.removeprefix(prefix):
        raise ValueError('Expected the closed synthetic Host identity')
    host_info = plist(host / 'Contents/Info.plist')
    if host_info.get('CFBundleIdentifier') != identifier or host_info.get('CFBundleExecutable') != 'Edith':
        raise ValueError('Fixture Host identity differs')
    verify(host)
    host_code = identity(host / 'Contents/MacOS/Edith')
    if host_code['signedSHA256'] != metadata['hostExecutableSHA256']:
        raise ValueError('Fixture Host executable digest differs')
    expected_resources = resources(host / 'Contents/Resources/EdithHost_EdithHost.bundle')
    source_host = Path(metadata['sourceHost'])
    if source_host.is_symlink() or not source_host.is_dir() or source_host.resolve() != source_host.absolute():
        raise ValueError('Source Host requires a canonical regular boundary')
    verify(source_host)
    source_code = identity(source_host / 'Contents/MacOS/Edith')
    if source_code['signedSHA256'] != metadata['sourceHostExecutableSHA256']:
        raise ValueError('Source Host executable receipt differs')
    if source_code['normalizedUnsignedSHA256'] != host_code['normalizedUnsignedSHA256']:
        raise ValueError('Re-signing changed the source Host executable code')
    if resources(source_host / 'Contents/Resources/EdithHost_EdithHost.bundle') != expected_resources:
        raise ValueError('Re-signing changed the source Host resources')
    carrier_source = carrier_input()
    if carrier_source["sourceCommit"] != metadata["sourceCommit"] or hashlib.sha256(carrier_source["path"].read_bytes()).hexdigest() != carrier_source["sha256"]:
        raise ValueError("Frozen carrier input differs")
    carrier_code = identity(carrier_source["path"])
    if carrier_code["signedSHA256"] != carrier_source["sha256"]:
        raise ValueError("Frozen carrier identity differs from its receipt")
    carrier = payload / 'ExtensionCarrier.app'
    worker = carrier / 'Contents/Extensions/ExtensionWorker.appex'
    copies = [('carrier', carrier, identifier + '.extension.' + owner), ('worker', worker, identifier + '.extension.' + owner + '.worker')]
    if owner == 'virtualCamera':
        copies.append(('cameraCarrier', payload / 'CameraCarrier.app', identifier + '.cameraCarrier'))
    result = {}
    for role, bundle, bundle_identifier in copies:
        verify(bundle)
        info = plist(bundle / 'Contents/Info.plist')
        expected = {'CFBundleIdentifier': bundle_identifier, 'CFBundleExecutable': 'Edith', 'CFBundleShortVersionString': metadata['version'], 'EdithHostIdentifier': identifier, 'EdithHostABI': metadata['hostABI'], 'EdithExecutableProvenance': metadata['hostExecutableSHA256']}
        if any(info.get(key) != value for key, value in expected.items()):
            raise ValueError('Fixture carrier metadata differs')
        if role == 'cameraCarrier':
            if info.get('EdithContainedRole') != role or info.get('EdithContainedExtensionID') != owner or info.get('EdithCameraTransport') != 'obs':
                raise ValueError('Camera auxiliary carrier ownership differs')
        elif info.get("EdithCarrierExecutableProvenance") != carrier_source["sha256"]:
            raise ValueError("Fixture carrier input provenance differs")
        elif info.get('EdithExtensionID') != owner or info.get('EdithExtensionVersion') != metadata['version'] or info.get('EdithHostExecutablePath') != str(host / 'Contents/MacOS/Edith'):
            raise ValueError('UI carrier sealed ownership differs')
        copied_code = identity(bundle / 'Contents/MacOS/Edith')
        expected_code = carrier_code if role == "carrier" else host_code
        if copied_code['normalizedUnsignedSHA256'] != expected_code['normalizedUnsignedSHA256']:
            raise ValueError('Fixture carrier executable code differs')
        copied_resources = resources(bundle / 'Contents/Resources/EdithHost_EdithHost.bundle')
        if copied_resources != expected_resources:
            raise ValueError('Fixture carrier Host resources differ')
        result[role] = {'identity': bundle_identifier, 'metadata': expected, 'code': copied_code, 'hostResources': copied_resources}
    expected_entitlements = {'com.apple.security.app-sandbox': True}
    if owner in ('music', 'notchShelf'):
        expected_entitlements['com.apple.security.network.client'] = True
    actual_entitlements = entitlements(worker)
    if actual_entitlements != expected_entitlements or any(type(value) is not bool for value in actual_entitlements.values()):
        raise ValueError('Fixture worker capabilities differ')
    return {'schema': 1, 'extensionID': owner, 'hostIdentifier': identifier, 'sourceHostCode': source_code, 'fixtureHostCode': host_code, 'carrierSourceCode': carrier_code, 'sourceHostResourcesUnchanged': True, 'copies': result, 'workerEntitlements': actual_entitlements, 'productionExecutableUnchangedProof': False, 'scope': 'Synthetic Host executable carriers only, excluded from native role payload equivalence', 'codeExecuted': False}


if __name__ == '__main__':
    if len(sys.argv) != 4:
        raise SystemExit('Supply fixture Host, payload and metadata receipt')
    print(json.dumps(fixture_host_inventory(sys.argv[1], sys.argv[2], json.loads(Path(sys.argv[3]).read_text())), sort_keys=True))
