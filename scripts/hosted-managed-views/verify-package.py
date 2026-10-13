import hashlib
import importlib.util
import json
import shutil
import stat
import subprocess
import sys
import zipfile
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from macho_code_identity import executable_identity
from package_extension_lifecycle_tools import carrier_input, checked_path


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def extract_regular(archive, target, *, expected_root=None, maximum_bytes=8 * 1024**3):
    target = Path(target)
    if target.exists():
        raise ValueError('Archive extraction requires a fresh destination')
    with zipfile.ZipFile(archive) as zipped:
        infos = zipped.infolist()
        if not infos or len(infos) > 100000 or len({entry.filename for entry in infos}) != len(infos):
            raise ValueError('Archive entry inventory is empty, duplicated or excessive')
        total = 0
        for entry in infos:
            path = PurePosixPath(entry.filename)
            if not path.parts or path.is_absolute() or '..' in path.parts or '\\' in entry.filename or '\0' in entry.filename or any(part in ('', '.') for part in entry.filename.rstrip('/').split('/')):
                raise ValueError('Unsafe archive member')
            if expected_root and path.parts[0] != expected_root:
                raise ValueError('Archive package root differs')
            kind = stat.S_IFMT(entry.external_attr >> 16)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR) or entry.flag_bits & 1:
                raise ValueError('Archive contains nonregular or encrypted members')
            if entry.file_size > 2 * 1024**3:
                raise ValueError('Archive member exceeds its size bound')
            total += entry.file_size
            if total > maximum_bytes:
                raise ValueError('Archive exceeds its expanded byte bound')
        if zipped.testzip() is not None:
            raise ValueError('Archive CRC differs')
        target.mkdir(mode=0o700)
        for entry in infos:
            output = target / entry.filename
            if entry.is_dir():
                output.mkdir(parents=True, exist_ok=True, mode=0o700)
                continue
            output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            with zipped.open(entry) as source, output.open('xb') as destination:
                shutil.copyfileobj(source, destination, 1024 * 1024)
            output.chmod((entry.external_attr >> 16) & 0o777 or 0o600)
    return total


def frozen_carrier_provider(directory):
    root = Path(__file__).resolve().parents[2]
    directory = checked_path(root, directory, directory=True)
    return lambda: carrier_input(root, directory / 'Edith.app', directory / 'carrier-tools')


def verify_package(artifact, directory, host, source_commit, fingerprint, host_hash, *, carrier_input_provider=None):
    directory, host = Path(directory), Path(host)
    definition = json.loads((directory / 'definition.json').read_text())
    identifier = definition['id']
    packages = directory / 'package'
    extract_regular(artifact, packages, maximum_bytes=2 * 1024**3)
    allowed = {f'{identifier}.zip', f'{identifier}.json', f'{identifier}.zip.sha256', f'{identifier}.ui-carrier-provenance.json'}
    if identifier == 'virtualCamera':
        allowed.add('virtualCamera.carrier-provenance.json')
    members = {path.relative_to(packages).as_posix() for path in packages.rglob('*') if path.is_file()}
    if not members.issubset(allowed) or not {f'{identifier}.zip', f'{identifier}.json', f'{identifier}.zip.sha256'}.issubset(members):
        raise ValueError('CI artifact contains unknown or missing package assets')
    if any(path.stat().st_size > 1024 * 1024 for path in packages.glob('*.json')):
        raise ValueError('Package JSON sidecar exceeds its document bound')
    metadata_path = packages / f'{identifier}.json'
    if metadata_path.stat().st_size > 1024 * 1024:
        raise ValueError('Package metadata exceeds its bound')
    metadata = json.loads(metadata_path.read_text())
    archive = packages / f'{identifier}.zip'
    with archive.open('rb') as source:
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    archive_hash = digest.hexdigest()
    if metadata.get('id') != identifier or metadata.get('sourceFingerprint') != fingerprint or metadata.get('sha256') != archive_hash or metadata.get('downloadBytes') != archive.stat().st_size:
        raise ValueError('Package source, identity, bytes or digest differs')
    if (packages / f'{identifier}.zip.sha256').read_bytes() != f'{archive_hash}  {identifier}.zip\n'.encode():
        raise ValueError('Detached checksum differs')
    expanded = directory / 'expanded'
    expanded_bytes = extract_regular(archive, expanded, expected_root=identifier)
    if metadata.get('installedBytes') != expanded_bytes:
        raise ValueError('Expanded package bytes differ')
    report = load('host_report', Path(__file__).resolve().parents[1] / 'extension-host-size-report.py')
    if report.digest_file(host / 'Contents/MacOS/Edith') != host_hash:
        raise ValueError('Frozen host digest differs')
    code_identity = executable_identity(host / 'Contents/MacOS/Edith')
    host_proof = report.verify_package_host(packages, metadata, definition, host, source_commit, host_hash, code_identity['normalizedUnsignedSHA256'], carrier_input_provider=carrier_input_provider)
    carrier = expanded / identifier / 'ExtensionCarrier.app'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(carrier)], check=True, capture_output=True, timeout=60)
    payload = carrier / 'Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload' / identifier
    inventory = load('role_inventory', Path(__file__).with_name('payload-inventory.py'))
    roles = {role: inventory.payload_inventory(payload / f'{role}.bundle') for role in definition['roles'] if role not in ('cameraCarrier', 'cameraProvider')}
    actual_roles = {path.name.removesuffix('.bundle') for path in payload.glob('*.bundle')}
    if actual_roles != set(roles):
        raise ValueError('Native role bundle inventory differs')
    return {'schema': 1, 'extensionID': identifier, 'sourceCommit': source_commit, 'sourceFingerprint': fingerprint,
            'sourceHostExecutableSHA256': host_hash, 'zipSHA256': archive_hash, 'downloadBytes': archive.stat().st_size,
            'installedBytes': expanded_bytes, 'zipCRCVerified': True, 'sealedHostProvenanceVerified': True,
            'signaturesVerified': True, 'hostProvenance': host_proof, 'roles': roles, 'packageCodeExecuted': False}


if __name__ == '__main__':
    if len(sys.argv) == 9 and sys.argv[7] == '--carrier-directory':
        provider = frozen_carrier_provider(sys.argv[8])
        print(json.dumps(verify_package(*sys.argv[1:7], carrier_input_provider=provider), sort_keys=True))
    else:
        if len(sys.argv) != 7:
            raise SystemExit('Supply artifact, destination, host, source commit, fingerprint and host checksum')
        print(json.dumps(verify_package(*sys.argv[1:]), sort_keys=True))
