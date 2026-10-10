import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile

BUNDLE = 'EdithHost_EdithHostCore.bundle'
RECEIPT = 'lifecycle-tools.json'
FILES = ['HostLifecycleHarness', 'MarketplaceHarness', BUNDLE + '/index.json']


def checked_path(root, value, directory=False):
    root = Path(root).absolute()
    path = Path(os.path.abspath(root / value))
    if path != root and root not in path.parents:
        raise ValueError('Lifecycle tool paths must remain inside the source workspace')
    current = path
    while True:
        metadata = current.lstat()
        expected = stat.S_ISDIR if current != path or directory else stat.S_ISREG
        if not expected(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
            raise ValueError('Lifecycle tool paths must be owned, regular and not writable by other users')
        if current == path and not directory and metadata.st_nlink != 1:
            raise ValueError('Lifecycle tool files must not be hard linked')
        if current == root:
            break
        current = current.parent
    return path


def read_file(root, value, maximum=134_217_728):
    path = checked_path(root, value)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_mode & 0o022 or before.st_nlink != 1 or before.st_size < 0 or before.st_size > maximum:
            raise ValueError('Lifecycle tool input is not a bounded regular file')
        with os.fdopen(descriptor, 'rb', closefd=False) as stream:
            data = stream.read(maximum + 1)
        after = os.fstat(descriptor)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if identity(before) != identity(after) or len(data) != before.st_size or len(data) > maximum:
            raise ValueError('Lifecycle tool input changed during reading')
        checked_path(root, path)
        return data, stat.S_IMODE(before.st_mode)
    finally:
        os.close(descriptor)


def index_bytes(root, host):
    source, _ = read_file(root, 'Packages/EdithHost/Sources/EdithHostCore/Resources/index.json', 1_048_576)
    manifest, _ = read_file(root, 'Extensions/manifest.json', 8_388_608)
    entries = json.loads(source)
    definitions = json.loads(manifest)
    if not isinstance(entries, list) or not isinstance(definitions, list) or len(entries) != 39 or len(definitions) != 39:
        raise ValueError('Lifecycle tools require the exact current39 source index and manifest')
    ids = [row.get('id') for row in entries if isinstance(row, dict)]
    declared = [row.get('id') for row in definitions if isinstance(row, dict)]
    if len(ids) != 39 or len(declared) != 39 or any(not isinstance(value, str) or not value for value in ids + declared) or len(set(ids)) != 39 or len(set(declared)) != 39 or set(ids) != set(declared):
        raise ValueError('Lifecycle tool index differs from the current39 manifest')
    if any(set(row) != {'id', 'title', 'symbolName', 'category'} or any(not isinstance(value, str) or not value for value in row.values()) for row in entries):
        raise ValueError('Lifecycle tool index contains invalid source entries')
    frozen, _ = read_file(root, Path(host) / 'Contents/Resources/index.json', 1_048_576)
    if frozen != source:
        raise ValueError('Frozen host index differs from the source index')
    return source


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def verify_tools(root, host, output):
    output = checked_path(root, output, directory=True)
    expected = index_bytes(root, host)
    receipt_bytes, _ = read_file(root, output / RECEIPT, 16_384)
    receipt = json.loads(receipt_bytes)
    if not isinstance(receipt, dict) or set(receipt) != {'schema', 'indexSHA256', 'files'} or type(receipt['schema']) is not int or receipt['schema'] != 1 or receipt['indexSHA256'] != sha256(expected):
        raise ValueError('Lifecycle tool receipt does not match the frozen source index')
    if not isinstance(receipt['files'], dict) or set(receipt['files']) != set(FILES):
        raise ValueError('Lifecycle tool receipt is incomplete')
    if {path.name for path in output.iterdir()} != {FILES[0], FILES[1], BUNDLE, RECEIPT}:
        raise ValueError('Lifecycle tool package contains unexpected files')
    bundle = checked_path(root, output / BUNDLE, directory=True)
    if {path.name for path in bundle.iterdir()} != {'index.json'}:
        raise ValueError('Lifecycle resource bundle contains unexpected files')
    for name in FILES:
        data, mode = read_file(root, output / name)
        record = receipt['files'][name]
        if record != {'sha256': sha256(data), 'bytes': len(data), 'mode': mode}:
            raise ValueError('Lifecycle tool copy differs from its receipt')
        if name.endswith('/index.json'):
            if data != expected:
                raise ValueError('Lifecycle resource bundle differs from the frozen source index')
        elif not mode & 0o111:
            raise ValueError('Lifecycle tool executable permission is missing')
    return receipt


def package_tools(root, host, host_products, marketplace_products, output):
    root = checked_path(root, '.', directory=True)
    output = Path(os.path.abspath(root / output))
    checked_path(root, output.parent, directory=True)
    if output.exists() or output.is_symlink():
        raise ValueError('Lifecycle tool output must be a new directory')
    expected = index_bytes(root, host)
    sources = {
        FILES[0]: Path(host_products) / FILES[0],
        FILES[1]: Path(marketplace_products) / FILES[1],
        FILES[2]: Path(host_products) / FILES[2],
    }
    copies = {name: read_file(root, path) for name, path in sources.items()}
    if copies[FILES[2]][0] != expected:
        raise ValueError('Built lifecycle resource bundle differs from the frozen source index')
    if any(not copies[name][1] & 0o111 for name in FILES[:2]):
        raise ValueError('Built lifecycle tools must be executable')
    with tempfile.TemporaryDirectory(prefix='lifecycle-tools-', dir=output.parent) as temporary:
        staging = Path(temporary) / 'tools'
        staging.mkdir(mode=0o700)
        (staging / BUNDLE).mkdir(mode=0o700)
        receipt = {'schema': 1, 'indexSHA256': sha256(expected), 'files': {}}
        for name, (data, mode) in copies.items():
            path = staging / name
            path.write_bytes(data)
            path.chmod(mode)
            receipt['files'][name] = {'sha256': sha256(data), 'bytes': len(data), 'mode': mode}
        (staging / RECEIPT).write_text(json.dumps(receipt, indent=2) + '\n')
        verify_tools(root, host, staging)
        for name, source in sources.items():
            if read_file(root, source) != copies[name]:
                raise ValueError('Lifecycle tool source changed during packaging')
        output.mkdir(mode=0o700)
        try:
            for path in staging.iterdir():
                shutil.move(str(path), output / path.name)
            return verify_tools(root, host, output)
        except BaseException:
            shutil.rmtree(output)
            raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--host-products', type=Path)
    parser.add_argument('--marketplace-products', type=Path)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    if args.verify:
        if args.host_products or args.marketplace_products:
            parser.error('--verify does not accept build products')
        receipt = verify_tools(args.root, args.host, args.output)
    else:
        if args.host_products is None or args.marketplace_products is None:
            parser.error('packaging requires both built product directories')
        receipt = package_tools(args.root, args.host, args.host_products, args.marketplace_products, args.output)
    print(json.dumps(receipt, sort_keys=True))


if __name__ == '__main__':
    main()
