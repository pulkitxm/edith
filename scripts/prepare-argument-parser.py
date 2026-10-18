import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import subprocess
import sys

REVISION = '6a52f3251125d74daf04fcbd5e6f08a75d074382'
SOURCES = {
    'Parsable Types/ParsableArguments.swift': (
        '1ad16fa584662bfe539dbbce2e2b9d305af40856f433a60439ecad71e4c9087e',
        '61f6360010c6f0e70b2e8f2480c301bd4b3f32639f0c5c086bfa57378ada351f'),
    'Usage/DumpHelpGenerator.swift': (
        '58cf01a02b40287691878c0b336213f72015bb1b1289f0fa5d7df3788396b1c3',
        'e9b9a4cd7a2f47a34ddf402ef19347eb94064c50cb11c4f5853bfafabc35912b'),
}


ENVIRONMENT_KEYS = {
    'PATH', 'HOME', 'CFFIXED_USER_HOME', 'TMPDIR', 'XDG_CACHE_HOME', 'XDG_CONFIG_HOME',
    'XDG_DATA_HOME', 'DEVELOPER_DIR', 'SDKROOT', 'LANG', 'LC_ALL', 'LC_CTYPE',
    'CLANG_MODULE_CACHE_PATH', 'SWIFTPM_MODULECACHE_OVERRIDE', 'SWIFT_MODULECACHE_PATH',
    'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'SSL_CERT_FILE', 'SSL_CERT_DIR',
    'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy',
}


def closed_environment():
    environment = {key: value for key, value in os.environ.items() if key in ENVIRONMENT_KEYS}
    environment.update(GIT_NO_REPLACE_OBJECTS='1', GIT_CONFIG_NOSYSTEM='1',
                       GIT_CONFIG_GLOBAL=os.devnull)
    return environment


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(value):
    return hashlib.sha256(value).hexdigest()


def identity(value):
    return (value.st_dev, value.st_ino, value.st_uid, value.st_mode, value.st_nlink,
            value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def directory(path):
    path = Path(path)
    require(path.is_absolute() and path.resolve() == path, 'Noncanonical dependency directory')
    value = path.lstat()
    require(stat.S_ISDIR(value.st_mode) and value.st_uid == os.getuid()
            and value.st_mode & 0o022 == 0, 'Unowned or writable dependency directory')
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        require(identity(os.fstat(descriptor)) == identity(value), 'Dependency directory changed')
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def read_file(path):
    parent = directory(path.parent)
    descriptor = None
    try:
        value = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        require(stat.S_ISREG(value.st_mode) and value.st_uid == os.getuid()
                and value.st_nlink == 1 and value.st_mode & 0o022 == 0
                and value.st_size <= 1_048_576, 'Invalid dependency source file')
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        require(identity(os.fstat(descriptor)) == identity(value), 'Dependency source changed')
        with os.fdopen(descriptor, 'rb', closefd=False) as stream:
            data = stream.read(1_048_577)
        require(identity(os.fstat(descriptor)) == identity(value)
                and identity(os.stat(path.name, dir_fd=parent, follow_symlinks=False)) == identity(value)
                and len(data) <= 1_048_576, 'Dependency source changed while reading')
        return data, value
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent)


def replace_file(path, data, previous):
    parent = directory(path.parent)
    temporary = '.argument-parser-' + secrets.token_hex(16)
    descriptor = None
    old_mode = stat.S_IMODE(os.fstat(parent).st_mode)
    try:
        require(identity(os.stat(path.name, dir_fd=parent, follow_symlinks=False)) == identity(previous),
                'Dependency source changed before replacement')
        os.fchmod(parent, old_mode | 0o200)
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=parent)
        opened = os.fstat(descriptor)
        require(stat.S_ISREG(opened.st_mode) and opened.st_uid == os.getuid()
                and opened.st_nlink == 1, 'Invalid replacement source')
        with os.fdopen(descriptor, 'wb', closefd=False) as stream:
            stream.write(data)
            stream.flush()
        os.fsync(descriptor)
        os.fchmod(descriptor, stat.S_IMODE(previous.st_mode))
        require(identity(os.stat(path.name, dir_fd=parent, follow_symlinks=False)) == identity(previous),
                'Dependency source changed during replacement')
        os.replace(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent)
        os.fsync(parent)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.fchmod(parent, old_mode)
        os.close(parent)


def rewrite(source, relative):
    module = Path(__file__).with_name('argument-parser-source.mjs').resolve().as_uri()
    program = ('import { rewriteArgumentParserWarnings } from ' + json.dumps(module)
               + '; let input=""; for await (const part of process.stdin) input+=part;'
               + 'const value=JSON.parse(input);process.stdout.write('
               + 'rewriteArgumentParserWarnings(value.source,value.path));')
    return subprocess.check_output(
        ['node', '--input-type=module', '-e', program],
        input=json.dumps({'source': source.decode('utf-8'), 'path': relative}).encode('utf-8'),
        env=closed_environment())


def validate_pin(package):
    manifest, _ = read_file(package / 'Package.swift')
    lock, _ = read_file(package / 'Package.resolved')
    pins = [item for item in json.loads(lock)['pins']
            if item.get('identity') == 'swift-argument-parser']
    require(len(pins) == 1 and pins[0].get('kind') == 'remoteSourceControl'
            and pins[0].get('location') in [
                'https://github.com/apple/swift-argument-parser',
                'https://github.com/apple/swift-argument-parser.git']
            and pins[0].get('state') == {'revision': REVISION, 'version': '1.8.2'},
            'ArgumentParser dependency pin changed')
    return manifest, lock


def audit_checkout(package, scratch, run):
    package, scratch = Path(package), Path(scratch)
    manifest, lock = validate_pin(package)
    require(scratch.is_relative_to(package) and scratch.resolve() == scratch,
            'Dependency checkout escaped package scratch path')
    directory_fd = directory(scratch)
    os.close(directory_fd)
    checkout = scratch / 'checkouts/swift-argument-parser'
    for path in [scratch / 'checkouts', checkout, checkout / '.git',
                 checkout / 'Sources', checkout / 'Sources/ArgumentParser']:
        descriptor = directory(path)
        os.close(descriptor)
    environment = closed_environment()
    git = ['git', '--no-optional-locks', '-c', 'core.fsmonitor=false',
           '-c', 'core.hooksPath=' + os.devnull, '-C', str(checkout)]
    require(run(git + ['rev-parse', '--show-toplevel'], env=environment).decode().strip()
            == str(checkout), 'ArgumentParser Git worktree changed')
    require(run(git + ['rev-parse', 'HEAD'], env=environment).decode().strip() == REVISION,
            'ArgumentParser checkout revision changed')
    state, _ = read_file(scratch / 'workspace-state.json')
    dependencies = [item for item in json.loads(state)['object']['dependencies']
                    if item.get('packageRef', {}).get('identity') == 'swift-argument-parser']
    locations = ['https://github.com/apple/swift-argument-parser',
                 'https://github.com/apple/swift-argument-parser.git']
    require(len(dependencies) == 1
            and dependencies[0].get('packageRef', {}).get('location') in locations
            and dependencies[0].get('packageRef', {}).get('kind') == 'remoteSourceControl'
            and dependencies[0].get('state') == {
                'checkoutState': {'revision': REVISION, 'version': '1.8.2'},
                'name': 'sourceControlCheckout'}
            and dependencies[0].get('subpath') == 'swift-argument-parser',
            'ArgumentParser resolved workspace changed')
    origin = run(git + ['remote', 'get-url', 'origin'], env=environment).decode().strip()
    repository = Path(origin)
    require(repository.is_absolute() and repository.parent == scratch / 'repositories'
            and repository.name.startswith('swift-argument-parser-'),
            'ArgumentParser checkout repository escaped workspace')
    repository_fd = directory(repository)
    os.close(repository_fd)
    require(run(['git', '--no-optional-locks', '-c', 'core.fsmonitor=false',
                 '-c', 'core.hooksPath=' + os.devnull, '-C', str(repository),
                 'remote', 'get-url', 'origin'],
                env=environment).decode().strip() in locations,
            'ArgumentParser checkout origin changed')
    changes = run(git + ['diff', '--no-ext-diff', '--no-textconv', '--name-only', 'HEAD', '--'], env=environment).decode().splitlines()
    expected = {'Sources/ArgumentParser/' + name for name in SOURCES}
    require(set(changes).issubset(expected), 'Unexpected ArgumentParser checkout changes')
    require(not run(git + ['ls-files', '--others'], env=environment).strip(),
            'Untracked ArgumentParser checkout sources')
    return {'manifest': manifest, 'lock': lock, 'workspace': state, 'origin': origin}


def prepare_checkout(package, scratch, run=subprocess.check_output):
    package, scratch = Path(package), Path(scratch)
    admitted = audit_checkout(package, scratch, run)
    checkout = scratch / 'checkouts/swift-argument-parser'
    prepared = []
    for relative, (before, after) in SOURCES.items():
        path = checkout / 'Sources/ArgumentParser' / relative
        source, metadata = read_file(path)
        actual = digest(source)
        require(actual in [before, after], 'Pinned ArgumentParser source changed')
        target = rewrite(source, relative) if actual == before else source
        require(digest(target) == after, 'ArgumentParser rewrite output changed')
        prepared.append((path, target, metadata, actual != after))
    require(audit_checkout(package, scratch, run) == admitted,
            'ArgumentParser checkout changed while rewriting')
    for path, target, metadata, changed in prepared:
        if changed:
            replace_file(path, target, metadata)
        require(read_file(path)[0] == target, 'ArgumentParser prepared source changed')
    require(audit_checkout(package, scratch, run) == admitted,
            'ArgumentParser checkout changed during preparation')
    manifest, lock = admitted['manifest'], admitted['lock']
    return {'schema': 1, 'revision': REVISION, 'package': str(package), 'scratch': str(scratch),
            'manifestSHA256': digest(manifest), 'lockSHA256': digest(lock),
            'sources': {name: {'before': value[0], 'after': value[1]}
                        for name, value in SOURCES.items()}}


def prepare(package, scratch=None):
    root = Path(__file__).resolve().parent.parent
    package = Path(package)
    if not package.is_absolute():
        package = root / package
    require(package.is_relative_to(root) and package != root, 'Unowned package root')
    original_manifest, original_lock = validate_pin(package)
    scratch = Path(scratch) if scratch is not None else package / '.build'
    if not scratch.is_absolute():
        scratch = package / scratch
    require(scratch.is_absolute() and scratch.is_relative_to(package)
            and scratch.resolve() == scratch, 'Unowned dependency scratch path')
    if scratch.exists():
        descriptor = directory(scratch)
        os.close(descriptor)
    subprocess.run(['swift', 'package', '--package-path', str(package), '--scratch-path', str(scratch),
                    '--jobs', '1', 'resolve'], check=True, env=closed_environment())
    manifest, lock = validate_pin(package)
    require(manifest == original_manifest and lock == original_lock,
            'Dependency resolution changed canonical manifest or lock')
    receipt = prepare_checkout(package, scratch)
    path = scratch / 'argument-parser-warning-rewrite.json'
    data = (json.dumps(receipt, sort_keys=True, separators=(',', ':')) + '\n').encode()
    if path.exists() or path.is_symlink():
        old, metadata = read_file(path)
        if old != data:
            replace_file(path, data, metadata)
    else:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)
    require(validate_pin(package) == (original_manifest, original_lock),
            'Preparation changed canonical manifest or lock')
    return receipt


if __name__ == '__main__':
    require(len(sys.argv) in [2, 4] and (len(sys.argv) == 2 or sys.argv[2] == '--scratch-path'),
            'Specify a package and optional scratch path')
    prepare(sys.argv[1], sys.argv[3] if len(sys.argv) == 4 else None)
    print('Prepared pinned ArgumentParser 1.8.2 warning sources')
