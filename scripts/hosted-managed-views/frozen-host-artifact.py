import argparse
import hashlib
import json
import os
import stat
import tarfile
import zipfile
from pathlib import Path, PurePosixPath


def unpack_frozen_host(archive, output, tree="minimal-host"):
    if tree not in ("minimal-host", "extension-release-host"):
        raise ValueError("Unknown frozen host tree")
    archive, output = Path(archive), Path(output)
    for path in (archive, output):
        if path.is_symlink() or path.resolve() != path.absolute():
            raise ValueError('Frozen artifact paths must be canonical')
    info = archive.lstat()
    root = output.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > 2 * 1024**3 or info.st_uid != os.getuid():
        raise ValueError('Frozen artifact must be a bounded owned regular file')
    if not stat.S_ISDIR(root.st_mode) or root.st_uid != os.getuid() or stat.S_IMODE(root.st_mode) != 0o700 or any(output.iterdir()):
        raise ValueError('Frozen artifact output must be fresh owned0700')
    seen, total, selected, links = {}, 0, [], []
    parents = set()
    launcher = 'local/extension-release-host/Edith.app/Contents/MacOS/ed'
    launcher_target = 'local/extension-release-host/Edith.app/Contents/Resources/ed-launcher'
    with zipfile.ZipFile(archive) as container:
        entries = container.infolist()
        if len(entries) != 1 or entries[0].filename != 'host.tar.gz' or entries[0].file_size > 2 * 1024**3:
            raise ValueError('Expected exactly the frozen host tar asset')
        outer = entries[0]
        kind = stat.S_IFMT(outer.external_attr >> 16)
        if kind not in (0, stat.S_IFREG) or container.testzip() is not None:
            raise ValueError('Frozen host container CRC or file type differs')
        with container.open(outer) as source, tarfile.open(fileobj=source, mode='r|gz') as tar:
            for entry in tar:
                name = entry.name.rstrip('/')
                parts = PurePosixPath(name).parts
                if not parts or name.startswith('/') or '\\' in name or '\0' in name or any(part in ('', '.', '..') for part in name.split('/')):
                    raise ValueError('Frozen tar path escapes its boundary')
                if name in seen or len(seen) >= 100000:
                    raise ValueError('Frozen tar contains duplicate or excessive paths')
                if any(seen.get(str(parent)) in ('file', 'link') for parent in PurePosixPath(name).parents):
                    raise ValueError('Frozen tar places an entry below a file or link')
                if name in parents and not entry.isdir():
                    raise ValueError('Frozen tar replaces a parent directory with a file or link')
                if entry.issym():
                    if name != launcher or entry.linkname != '../Resources/ed-launcher' or entry.size != 0:
                        raise ValueError('Frozen tar contains an unexpected symbolic link')
                    links.append(name)
                elif not (entry.isdir() or entry.isfile()):
                    raise ValueError('Frozen tar contains an unsupported entry type')
                if entry.mode & 0o7000:
                    raise ValueError('Frozen tar contains a link or unsafe mode')
                seen[name] = 'link' if entry.issym() else 'file' if entry.isfile() else 'directory'
                parents.update(str(parent) for parent in PurePosixPath(name).parents)
                if entry.size < 0 or entry.size > 2 * 1024**3:
                    raise ValueError('Frozen tar entry exceeds its bound')
                total += entry.size
                if total > 4 * 1024**3:
                    raise ValueError('Frozen tar expanded bytes exceed their bound')
                if name == 'local':
                    if not entry.isdir():
                        raise ValueError('Frozen tar root is not a directory')
                    continue
                if len(parts) < 2 or parts[0] != 'local' or parts[1] not in ('minimal-host', 'extension-tools', 'extension-release-host'):
                    raise ValueError('Frozen tar contains an unexpected source tree')
                if parts[1] != tree:
                    continue
                if entry.issym():
                    continue
                destination = output.joinpath(*parts[2:])
                if destination == output:
                    if not entry.isdir():
                        raise ValueError('Frozen host root is not a directory')
                    continue
                if destination.exists():
                    if not entry.isdir() or not destination.is_dir():
                        raise ValueError('Frozen tar changes an existing path type')
                    continue
                destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                if destination.parent.resolve() != destination.parent:
                    raise ValueError('Frozen host extraction escaped its boundary')
                if entry.isdir():
                    destination.mkdir(mode=entry.mode & 0o777)
                else:
                    stream = tar.extractfile(entry)
                    if stream is None:
                        raise ValueError('Frozen tar entry is unreadable')
                    with stream, destination.open('xb') as target:
                        remaining = entry.size
                        while remaining:
                            chunk = stream.read(min(1024 * 1024, remaining))
                            if not chunk:
                                raise ValueError('Frozen tar entry is truncated')
                            target.write(chunk)
                            remaining -= len(chunk)
                    destination.chmod(entry.mode & 0o777)
                    selected.append(name)
    if links:
        if seen.get(launcher_target) != 'file':
            raise ValueError('Frozen launcher target is not an archived regular file')
        if tree == 'extension-release-host':
            destination = output.joinpath(*PurePosixPath(launcher).parts[2:])
            target = output.joinpath(*PurePosixPath(launcher_target).parts[2:])
            target_info = target.lstat()
            bundle = output / 'Edith.app'
            if not stat.S_ISREG(target_info.st_mode) or target_info.st_uid != os.getuid() or target.resolve() != target.absolute() or bundle not in target.parents:
                raise ValueError('Frozen launcher target is not an owned in-bundle regular file')
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if destination.parent.resolve() != destination.parent or destination.exists() or destination.is_symlink():
                raise ValueError('Frozen launcher destination is not a fresh canonical path')
            destination.symlink_to('../Resources/ed-launcher')
    host = output / 'Edith.app'
    metadata = output / 'build-metadata.json'
    if not (host / 'Contents/MacOS/Edith').is_file() or not (host / 'Contents/Info.plist').is_file() or not metadata.is_file():
        raise ValueError('Frozen host executable or build metadata is missing')
    if metadata.stat().st_size > 1024 * 1024:
        raise ValueError('Frozen host build metadata exceeds its bound')
    digest = hashlib.sha256()
    with archive.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return {'schema': 1, 'hostApp': str(host), 'hostBuildMetadata': str(metadata), 'artifactSHA256': digest.hexdigest(), 'extractedFiles': len(selected), 'codeExecuted': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('artifact_zip')
    parser.add_argument('output')
    parser.add_argument('--tree', choices=('minimal-host', 'extension-release-host'), default='minimal-host')
    args = parser.parse_args()
    print(json.dumps(unpack_frozen_host(args.artifact_zip, args.output, args.tree), sort_keys=True))
