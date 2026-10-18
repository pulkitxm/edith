from pathlib import Path
import os
import plistlib
import re
import selectors
import stat
import subprocess
import sys
import time


LIMIT = 1048576
MOUNT_PARTS = ('Library', 'Developer', 'DVTDownloads', 'MetalToolchain', 'mounts')
DEVICE = re.compile(r'/dev/disk[0-9]+(?:s[0-9]+)*')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(arguments):
    process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = bytearray()
    deadline = time.monotonic() + 20
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                require(remaining > 0, 'Fixture cleanup command exceeded its deadline')
                for key, _ in selector.select(min(remaining, 0.25)):
                    chunk = os.read(key.fileobj.fileno(), 4096)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        output.extend(chunk)
                        require(len(output) <= LIMIT, 'Fixture cleanup output exceeds its bound')
            require(process.wait(timeout=max(0.01, deadline - time.monotonic())) == 0,
                    'Fixture cleanup command failed')
        return bytes(output)
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
        process.stdout.close()


def identity(path):
    info = path.lstat()
    return info.st_dev, info.st_ino, info.st_uid, info.st_mode


def owned_directory(path, private=False):
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and info.st_mode & 0o022 == 0 and path.resolve() == path,
            'Fixture path must be an owned canonical directory')
    if private:
        require(stat.S_IMODE(info.st_mode) == 0o700 and path.name.startswith('edith-keep-awake-tests.'),
                'Fixture root must be a private Keep Awake test directory')
    return identity(path)


def readonly(path):
    return bool(os.statvfs(path).f_flag & os.ST_RDONLY)


def inventory(raw, fixture, mounted=os.path.ismount, read_only=readonly):
    require(isinstance(raw, bytes) and len(raw) <= LIMIT, 'Invalid mount inventory size')
    value = plistlib.loads(raw)
    require(isinstance(value, dict) and isinstance(value.get('images'), list)
            and len(value['images']) <= 128, 'Invalid disk image inventory')
    root = fixture.joinpath(*MOUNT_PARTS)
    selected = {}
    devices = set()
    all_mounts = set()
    for image in value['images']:
        require(isinstance(image, dict) and isinstance(image.get('system-entities'), list)
                and len(image['system-entities']) <= 1024, 'Invalid disk image entities')
        mounts = {}
        for entity in image['system-entities']:
            require(isinstance(entity, dict) and isinstance(entity.get('dev-entry'), str)
                    and DEVICE.fullmatch(entity['dev-entry']) is not None,
                    'Invalid disk image device')
            require(entity['dev-entry'] not in devices, 'Duplicate disk image device')
            devices.add(entity['dev-entry'])
            if 'mount-point' not in entity:
                continue
            raw_path = entity['mount-point']
            require(isinstance(raw_path, str) and raw_path.startswith('/')
                    and '\0' not in raw_path, 'Invalid image mount path')
            path = Path(raw_path)
            require(str(path) == raw_path and '..' not in path.parts,
                    'Noncanonical image mount path')
            require(path not in all_mounts, 'Duplicate image mount point')
            all_mounts.add(path)
            mounts[path] = entity['dev-entry']
        targets = [path for path in mounts if path == fixture or fixture in path.parents]
        if not targets:
            continue
        require(len(targets) == len(mounts), 'Fixture image also mounts outside the fixture')
        for path in targets:
            require(path.parent == root, 'Unexpected mounted target under fixture')
            ancestor = fixture
            for part in MOUNT_PARTS:
                ancestor = ancestor / part
                owned_directory(ancestor)
            require(path.resolve() == path and stat.S_ISDIR(path.lstat().st_mode)
                    and mounted(path) and read_only(path), 'Target must be a canonical readonly mounted directory')
        require(len(targets) == 1, 'Fixture image has multiple mounted targets')
        selected[targets[0]] = mounts[targets[0]]
    require(len(selected) <= 16, 'Too many fixture disk images')
    return selected


def reject_unknown_mounts(fixture, known, mounted):
    count = 0
    pending = [fixture]
    while pending:
        path = pending.pop()
        count += 1
        require(count <= 100000, 'Fixture inventory exceeds its entry bound')
        if path in known:
            continue
        require(not mounted(path), 'Unknown mounted target under fixture')
        with os.scandir(path) as children:
            for child in children:
                if child.is_dir(follow_symlinks=False):
                    pending.append(Path(child.path))


def cleanup(fixture, run=command, mounted=os.path.ismount, read_only=readonly):
    fixture = Path(fixture)
    seal = owned_directory(fixture, private=True)
    initial = run(['/usr/bin/hdiutil', 'info', '-plist'])
    targets = inventory(initial, fixture, mounted, read_only)
    reject_unknown_mounts(fixture, set(targets), mounted)
    devices = dict(targets)
    seals = {path: identity(path) for path in targets}
    for target in sorted(targets):
        require(identity(fixture) == seal, 'Fixture root changed before cleanup')
        current = inventory(run(['/usr/bin/hdiutil', 'info', '-plist']), fixture, mounted, read_only)
        require(current == devices, 'Fixture mount inventory changed before detach')
        require(all(identity(path) == item for path, item in seals.items()),
                'Fixture mount identity changed before detach')
        reject_unknown_mounts(fixture, set(current), mounted)
        require(owned_directory(fixture, private=True) == seal, 'Fixture root changed before detach')
        run(['/usr/bin/hdiutil', 'detach', str(target)])
        del seals[target]
        del devices[target]
    require(identity(fixture) == seal, 'Fixture root changed after cleanup')
    remaining = inventory(run(['/usr/bin/hdiutil', 'info', '-plist']), fixture, mounted, read_only)
    require(not remaining, 'Fixture mounts remain after detach')
    reject_unknown_mounts(fixture, set(), mounted)


if __name__ == '__main__':
    require(len(sys.argv) == 2, 'Expected exactly one private fixture path')
    cleanup(sys.argv[1])
