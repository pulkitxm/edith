import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path
import shutil
import stat
import tempfile

BUNDLE = 'EdithHost_EdithHostCore.bundle'
RECEIPT = 'lifecycle-tools.json'
FILES = ['HostLifecycleHarness', 'MarketplaceHarness', BUNDLE + '/index.json', 'EdithExtensionCarrier']


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


def source_binding(root, host):
    data, _ = read_file(root, Path(host).parent / 'build-metadata.json', 1_048_576)
    metadata = json.loads(data)
    source = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    executable, _ = read_file(root, Path(host) / 'Contents/MacOS/Edith')
    digest = sha256(executable)
    if not isinstance(metadata, dict) or not re.fullmatch('[a-f0-9]{40}', source) or metadata.get('sourceCommit') != source or metadata.get('sourceTreeDirty') is not False or metadata.get('hostExecutableSHA256') != digest:
        raise ValueError('Lifecycle tools require the exact clean frozen source and minimal host')
    return source, digest


def verify_tools(root, host, output, carrier=False):
    output = checked_path(root, output, directory=True)
    expected = index_bytes(root, host)
    source, host_digest = source_binding(root, host)
    receipt_bytes, _ = read_file(root, output / RECEIPT, 16_384)
    receipt = json.loads(receipt_bytes)
    if not isinstance(receipt, dict) or set(receipt) != {'kind', 'schema', 'sourceCommit', 'hostExecutableSHA256', 'indexSHA256', 'files'} or type(receipt['schema']) is not int or receipt['schema'] != 2 or receipt['kind'] not in (('lifecycle', 'carrier') if carrier else ('lifecycle',)) or receipt['sourceCommit'] != source or receipt['hostExecutableSHA256'] != host_digest or receipt['indexSHA256'] != sha256(expected):
        raise ValueError('Lifecycle tool receipt does not match the frozen source index')
    selected = FILES if receipt['kind'] == 'lifecycle' else FILES[2:]
    if not isinstance(receipt['files'], dict) or set(receipt['files']) != set(selected):
        raise ValueError('Lifecycle tool receipt is incomplete')
    if {path.name for path in output.iterdir()} != {name.split('/')[0] for name in selected} | {RECEIPT}:
        raise ValueError('Lifecycle tool package contains unexpected files')
    bundle = checked_path(root, output / BUNDLE, directory=True)
    if {path.name for path in bundle.iterdir()} != {'index.json'}:
        raise ValueError('Lifecycle resource bundle contains unexpected files')
    for name in selected:
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


def package_tools(root, host, host_products, marketplace_products, output, carrier_products=None, carrier_only=False):
    root = checked_path(root, '.', directory=True)
    output = Path(os.path.abspath(root / output))
    checked_path(root, output.parent, directory=True)
    if output.exists() or output.is_symlink():
        raise ValueError('Lifecycle tool output must be a new directory')
    expected = index_bytes(root, host)
    source, host_digest = source_binding(root, host)
    sources = {
        FILES[0]: Path(host_products or root) / FILES[0],
        FILES[1]: Path(marketplace_products or root) / FILES[1],
        FILES[2]: Path(host_products or root) / FILES[2],
        FILES[3]: Path(carrier_products or host_products) / FILES[3],
    }
    if carrier_only:
        sources = {FILES[2]: root / "Packages/EdithHost/Sources/EdithHostCore/Resources/index.json", FILES[3]: Path(carrier_products) / FILES[3]}
    copies = {name: read_file(root, path) for name, path in sources.items()}
    if copies[FILES[2]][0] != expected:
        raise ValueError('Built lifecycle resource bundle differs from the frozen source index')
    if any(not copies[name][1] & 0o111 for name in sources if name != FILES[2]):
        raise ValueError('Built lifecycle tools must be executable')
    with tempfile.TemporaryDirectory(prefix='lifecycle-tools-', dir=output.parent) as temporary:
        staging = Path(temporary) / 'tools'
        staging.mkdir(mode=0o700)
        (staging / BUNDLE).mkdir(mode=0o700)
        receipt = {'kind': 'carrier' if carrier_only else 'lifecycle', 'schema': 2, 'sourceCommit': source, 'hostExecutableSHA256': host_digest, 'indexSHA256': sha256(expected), 'files': {}}
        for name, (data, mode) in copies.items():
            path = staging / name
            path.write_bytes(data)
            path.chmod(mode)
            receipt['files'][name] = {'sha256': sha256(data), 'bytes': len(data), 'mode': mode}
        (staging / RECEIPT).write_text(json.dumps(receipt, indent=2) + '\n')
        verify_tools(root, host, staging, carrier=carrier_only)
        for name, source in sources.items():
            if read_file(root, source) != copies[name]:
                raise ValueError('Lifecycle tool source changed during packaging')
        output.mkdir(mode=0o700)
        try:
            for path in staging.iterdir():
                shutil.move(str(path), output / path.name)
            return verify_tools(root, host, output, carrier=carrier_only)
        except BaseException:
            shutil.rmtree(output)
            raise


def carrier_input(root=None, host=None, tools=None):
    root = Path(root or Path(__file__).resolve().parent.parent).absolute()
    host = Path(host or root / 'local/minimal-host/Edith.app')
    tools = Path(tools or root / 'local/minimal-host/carrier-tools')
    receipt = verify_tools(root, host, tools, carrier=True)
    path = tools / FILES[3]
    data, mode = read_file(root, path)
    record = receipt['files'][FILES[3]]
    if record != {'sha256': sha256(data), 'bytes': len(data), 'mode': mode} or verify_tools(root, host, tools, carrier=True) != receipt:
        raise ValueError('Frozen UI carrier input changed during validation')
    return {'path': path, 'sha256': record['sha256'], 'sourceCommit': receipt['sourceCommit'], 'hostExecutableSHA256': receipt['hostExecutableSHA256']}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--host-products', type=Path)
    parser.add_argument('--marketplace-products', type=Path)
    parser.add_argument('--carrier-products', type=Path)
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--carrier-only', action='store_true')
    parser.add_argument('--verify-carrier', action='store_true')
    args = parser.parse_args()
    if args.verify:
        if args.host_products or args.marketplace_products or args.carrier_products:
            parser.error('--verify does not accept build products')
        receipt = verify_tools(args.root, args.host, args.output, carrier=args.verify_carrier)
    else:
        if args.carrier_only:
            if args.carrier_products is None:
                parser.error("carrier packaging requires the Release product directory")
        elif args.host_products is None or args.marketplace_products is None:
            parser.error("packaging requires both built product directories")
        receipt = package_tools(args.root, args.host, args.host_products, args.marketplace_products, args.output, args.carrier_products, args.carrier_only)
    print(json.dumps(receipt, sort_keys=True))


if __name__ == '__main__':
    main()
