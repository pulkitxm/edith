import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys


HASH = re.compile('[a-f0-9]{64}')
FIELDS = {'schema', 'kind', 'root', 'owner', 'version', 'sourceRoot', 'sourceCommit', 'sourceSHA256', 'toolchainSHA256', 'host', 'hostExecutableSHA256', 'carrier', 'index'}


def checked_path(root, path, directory=False):
    root, path = Path(root), Path(path)
    if not root.is_absolute() or root != Path(os.path.abspath(root)) or path != root and root not in path.parents:
        raise ValueError('Functional carrier path escaped its owned session')
    if path != Path(os.path.abspath(path)):
        raise ValueError('Functional carrier path is not absolute and canonical')
    current = path
    while True:
        info = current.lstat()
        expected = stat.S_ISDIR if current != path or directory else stat.S_ISREG
        if not expected(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise ValueError('Functional carrier path is not owned and regular')
        if current == root:
            if stat.S_IMODE(info.st_mode) != 0o700 or root.resolve() != root:
                raise ValueError('Functional carrier session is not private and canonical')
            break
        current = current.parent
    return path


def read_pin(root, record, maximum):
    if not isinstance(record, dict) or set(record) != {'path', 'sha256', 'bytes', 'mode'} or not isinstance(record['path'], str) or not isinstance(record['sha256'], str) or not HASH.fullmatch(record['sha256']) or type(record['bytes']) is not int or not 0 < record['bytes'] <= maximum or type(record['mode']) is not int:
        raise ValueError('Malformed functional carrier file pin')
    path = checked_path(root, record['path'])
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1 or before.st_size != record['bytes'] or stat.S_IMODE(before.st_mode) != record['mode']:
            raise ValueError('Functional carrier file identity differs')
        with os.fdopen(descriptor, 'rb', closefd=False) as stream:
            data = stream.read(record['bytes'] + 1)
        after = os.fstat(descriptor)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_uid, value.st_nlink, value.st_mode, value.st_mtime_ns, value.st_ctime_ns)
        if identity(before) != identity(after) or len(data) != record['bytes'] or hashlib.sha256(data).hexdigest() != record['sha256']:
            raise ValueError('Functional carrier file changed')
        checked_path(root, path)
        return data
    finally:
        os.close(descriptor)


def functional_carrier_provider(document, *, host, source_commit, host_hash, owner, version):
    if not isinstance(document, dict) or set(document) != FIELDS or type(document['schema']) is not int or document['schema'] != 1 or document['kind'] != 'functional-role-carrier':
        raise ValueError('Malformed functional carrier verification context')
    if document['host'] != str(host) or document['sourceCommit'] != source_commit or document['hostExecutableSHA256'] != host_hash or document['owner'] != owner or document['version'] != version:
        raise ValueError('Functional carrier verification context differs')
    if not isinstance(source_commit, str) or not re.fullmatch('[a-f0-9]{40}', source_commit) or not re.fullmatch('[A-Za-z][A-Za-z0-9]{0,63}', owner) or version not in ('1.0.0', '1.1.0'):
        raise ValueError('Invalid functional carrier source or owner')
    for field in ('sourceSHA256', 'toolchainSHA256', 'hostExecutableSHA256'):
        if not isinstance(document[field], str) or not HASH.fullmatch(document[field]):
            raise ValueError('Invalid functional carrier authority pin')
    if any(not isinstance(document[field], str) for field in ('root', 'sourceRoot', 'host')) or any(not isinstance(document[field], dict) or set(document[field]) != {'path', 'sha256', 'bytes', 'mode'} for field in ('carrier', 'index')):
        raise ValueError('Malformed functional carrier paths or records')
    root = checked_path(document['root'], document['root'], directory=True)
    if document['sourceRoot'] != str(root / f'source-{owner}-{version}') or str(host) != str(root / 'Fixture.app') or document['carrier']['path'] != str(root / 'RoleCarrier/EdithExtensionCarrier') or document['carrier']['mode'] != 0o500:
        raise ValueError('Functional carrier owner or archive root differs')
    checked_path(root, document['sourceRoot'], directory=True)
    checked_path(root, host, directory=True)
    host_executable = root / 'Fixture.app/Contents/MacOS/Edith'
    host_metadata = checked_path(root, host_executable).stat()
    host_record = {'path': str(host_executable), 'bytes': host_metadata.st_size, 'mode': stat.S_IMODE(host_metadata.st_mode), 'sha256': host_hash}
    read_pin(root, host_record, 134217728)
    index = read_pin(root, document['index'], 1048576)
    frozen_index = Path(host) / 'Contents/Resources/index.json'
    index_metadata = checked_path(root, frozen_index).stat()
    if read_pin(root, {'path': str(frozen_index), 'sha256': document['index']['sha256'], 'bytes': len(index), 'mode': stat.S_IMODE(index_metadata.st_mode)}, 1048576) != index:
        raise ValueError('Functional carrier source and host indexes differ')
    carrier = read_pin(root, document['carrier'], 134217728)
    identity = {'path': Path(document['carrier']['path']), 'sha256': hashlib.sha256(carrier).hexdigest(), 'sourceCommit': source_commit, 'hostExecutableSHA256': host_hash}

    def provide():
        read_pin(root, host_record, 134217728)
        if read_pin(root, document['index'], 1048576) != index or read_pin(root, {'path': str(frozen_index), 'sha256': document['index']['sha256'], 'bytes': len(index), 'mode': stat.S_IMODE(index_metadata.st_mode)}, 1048576) != index or read_pin(root, document['carrier'], 134217728) != carrier:
            raise ValueError('Functional carrier verification lifetime changed')
        return dict(identity)

    provide()
    return provide


def main(arguments):
    if len(arguments) != 6:
        raise ValueError('Supply artifact, destination, host, source commit, fingerprint and host checksum')
    raw = sys.stdin.buffer.read(65537)
    if not raw or len(raw) > 65536:
        raise ValueError('Functional carrier verification context exceeds its bound')
    document = json.loads(raw)
    artifact, directory, host, source_commit, fingerprint, host_hash = arguments
    definition = json.loads((Path(directory) / 'definition.json').read_text())
    provider = functional_carrier_provider(document, host=host, source_commit=source_commit, host_hash=host_hash, owner=definition['id'], version=document['version'])
    root = Path(document['root'])
    if Path(directory) != root / f"verify-{document['owner']}-{document['version']}" or Path(artifact) != root / f"native-{document['owner']}-{document['version']}.zip":
        raise ValueError('Functional package verification paths differ from the admitted pair')
    checked_path(root, directory, directory=True)
    checked_path(root, artifact)
    verifier_path = Path(__file__).parent.parent / 'hosted-managed-views/verify-package.py'
    spec = importlib.util.spec_from_file_location('functional_package_verifier', verifier_path)
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    result = verifier.verify_package(*arguments, carrier_input_provider=provider)
    provider()
    metadata = json.loads((Path(directory) / 'package' / f"{document['owner']}.json").read_text())
    if metadata.get('version') != document['version']:
        raise ValueError('Functional verified package version differs')
    if result['extensionID'] != document['owner']:
        raise ValueError('Functional verified package owner differs')
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main(sys.argv[1:])
