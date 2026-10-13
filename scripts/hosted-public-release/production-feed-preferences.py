import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import secrets
import stat
import sys


DOMAIN = 'com.pulkit.edith.plist'
KEY = 'SUFeedURL'
MAXIMUM = 65536


def require(value, message):
    if not value:
        raise ValueError(message)


def identity(value):
    return (value.st_dev, value.st_ino, value.st_uid, value.st_mode, value.st_nlink,
            value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def directory(path, *, create=False):
    require(path.is_absolute() and path.resolve() == path, 'Noncanonical preference directory')
    if create:
        path.mkdir(mode=0o700, exist_ok=True)
    value = path.lstat()
    require(stat.S_ISDIR(value.st_mode) and value.st_uid == os.getuid()
            and stat.S_IMODE(value.st_mode) == 0o700, 'Require an owned private preference directory')
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        require(identity(os.fstat(descriptor)) == identity(value), 'Preference directory changed')
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def read(descriptor, name):
    try:
        before = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return None, None
    require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
            and before.st_nlink == 1 and stat.S_IMODE(before.st_mode) == 0o600
            and 0 < before.st_size <= MAXIMUM, 'Invalid preference file')
    held = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptor)
    try:
        require(identity(os.fstat(held)) == identity(before), 'Preference inode changed')
        with os.fdopen(os.dup(held), 'rb') as stream:
            data = stream.read(MAXIMUM + 1)
        require(len(data) == before.st_size and identity(os.fstat(held)) == identity(before)
                == identity(os.stat(name, dir_fd=descriptor, follow_symlinks=False)), 'Preference file changed')
        return data, before
    finally:
        os.close(held)


def replace(descriptor, name, data, previous):
    require(0 < len(data) <= MAXIMUM, 'Preference document exceeds bound')
    temporary = '.feed-' + secrets.token_hex(16)
    held = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=descriptor)
    try:
        with os.fdopen(os.dup(held), 'wb') as stream:
            stream.write(data)
            stream.flush()
        os.fsync(held)
        _, current = read(descriptor, name)
        require((current is None and previous is None)
                or (current is not None and previous is not None and identity(current) == identity(previous)), 'Concurrent preference replacement')
        os.rename(temporary, name, src_dir_fd=descriptor, dst_dir_fd=descriptor)
        os.fsync(descriptor)
        require(read(descriptor, name)[0] == data, 'Preference commit differs')
    finally:
        os.close(held)
        try:
            os.unlink(temporary, dir_fd=descriptor)
        except FileNotFoundError:
            pass


def preferences(data):
    value = plistlib.loads(data) if data is not None else {}
    require(type(value) is dict and len(value) <= 1024 and all(type(key) is str for key in value), 'Invalid preference dictionary')
    require(KEY not in value or (type(value[KEY]) is str and len(value[KEY].encode()) <= 4096 and '\0' not in value[KEY]), 'Invalid saved feed preference')
    return value


def scope(home, version, receipt):
    home, receipt = Path(home), Path(receipt)
    require(len(version) <= 64 and re.fullmatch(r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)', version) is not None, 'Invalid public release version')
    require(home.is_absolute() and home.resolve(strict=True) == home, 'Noncanonical account home')
    value = home.lstat()
    require(stat.S_ISDIR(value.st_mode) and value.st_uid == os.getuid() and not value.st_mode & 0o022, 'Unowned account home')
    library = home / 'Library'
    held = directory(library, create=True)
    os.close(held)
    held = directory(library / 'Preferences', create=True)
    try:
        state = directory(receipt.parent)
    except BaseException:
        os.close(held)
        raise
    if receipt.name != 'sparkle-feed-route.json':
        os.close(held)
        os.close(state)
        raise ValueError('Unexpected feed receipt name')
    return held, state, f'https://github.com/pulkitxm/edith/releases/download/v{version}/appcast.xml'


def synchronize_key(held, path, value, previous, synchronize):
    def current_parent():
        before, current = os.fstat(held), path.parent.lstat()
        require(path.parent.resolve(strict=True) == path.parent and stat.S_ISDIR(current.st_mode)
                and (before.st_dev, before.st_ino, before.st_uid, before.st_mode)
                == (current.st_dev, current.st_ino, current.st_uid, current.st_mode), 'Preference parent changed')
    current_parent()
    _, current = read(held, DOMAIN)
    require((current is None and previous is None) or (current is not None and previous is not None
            and identity(current) == identity(previous)), 'Concurrent preference replacement before synchronization')
    require(synchronize(value) == value, 'Preference cache readback differs')
    current_parent()
    data, _ = read(held, DOMAIN)
    observed = preferences(data)
    require((KEY in observed) == (value is not None) and observed.get(KEY) == value, 'Physical preference readback differs')


def setup(home, version, receipt, synchronize):
    held, state, url = scope(home, version, receipt)
    try:
        data, previous = read(held, DOMAIN)
        value = preferences(data)
        record = {'schema': 1, 'home': str(home), 'url': url, 'originalPresent': KEY in value,
                  'originalValue': value.get(KEY)}
        require(read(state, Path(receipt).name)[0] is None, 'Feed route already admitted')
        replace(state, Path(receipt).name, json.dumps(record, sort_keys=True).encode(), None)
        synchronize_key(held, Path(home) / 'Library/Preferences' / DOMAIN, url, previous, synchronize)
        return {'route': 'isolated-public-prerelease', 'url': url}
    finally:
        os.close(held)
        os.close(state)


def restore(home, version, receipt, synchronize):
    held, state, url = scope(home, version, receipt)
    try:
        data, _ = read(state, Path(receipt).name)
        if data is None:
            return {'restored': False, 'routeNotStarted': True}
        def unique(pairs):
            value = {}
            for key, item in pairs:
                require(key not in value, 'Duplicate feed receipt key')
                value[key] = item
            return value
        record = json.loads(data, object_pairs_hook=unique, parse_constant=lambda _: require(False, 'Invalid feed receipt constant'))
        require(type(record) is dict and set(record) == {'schema', 'home', 'url', 'originalPresent', 'originalValue'}
                and type(record['schema']) is int and record['schema'] == 1 and record['home'] == str(home) and record['url'] == url
                and type(record['originalPresent']) is bool, 'Feed receipt identity differs')
        require((record['originalPresent'] and type(record['originalValue']) is str and len(record['originalValue'].encode()) <= 4096 and '\0' not in record['originalValue'])
                or (not record['originalPresent'] and record['originalValue'] is None), 'Invalid original feed receipt')
        data, previous = read(held, DOMAIN)
        value = preferences(data)
        if value.get(KEY) != url:
            require((KEY in value) == record['originalPresent'] and value.get(KEY) == record['originalValue'], 'Feed preference changed outside admitted route')
            synchronize_key(held, Path(home) / 'Library/Preferences' / DOMAIN, record['originalValue'], previous, synchronize)
            return {'restored': True, 'alreadyOriginal': True}
        synchronize_key(held, Path(home) / 'Library/Preferences' / DOMAIN, record['originalValue'], previous, synchronize)
        return {'restored': True, 'route': 'isolated-public-prerelease'}
    finally:
        os.close(held)
        os.close(state)


def hosted_account(home):
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
            and os.environ.get('RUNNER_OS') == 'macOS' and os.environ.get('GITHUB_REPOSITORY') == 'pulkitxm/edith'
            and os.environ.get('GITHUB_REPOSITORY_ID') == '1289153439'
            and os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch' and os.environ.get('GITHUB_REF') == 'refs/heads/main'
            and os.environ.get('GITHUB_ACTOR_ID') in ('65671483', '320458784'), 'Feed route requires admitted hosted runner')
    require(sys.platform == 'darwin' and home == os.environ.get('HOME')
            and Path(home).resolve(strict=True) == Path(pwd.getpwuid(os.getuid()).pw_dir).resolve(strict=True), 'Feed route account differs')


def native_synchronize(value):
    hosted_account(os.environ.get('HOME', ''))
    import ctypes
    core = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    pointer, index, boolean = ctypes.c_void_p, ctypes.c_long, ctypes.c_ubyte
    signatures = {
        'CFStringCreateWithBytes': ([pointer, ctypes.c_char_p, index, ctypes.c_uint32, boolean], pointer),
        'CFStringGetCString': ([pointer, pointer, index, ctypes.c_uint32], boolean),
        'CFStringGetTypeID': ([], ctypes.c_ulong),
        'CFGetTypeID': ([pointer], ctypes.c_ulong),
        'CFRelease': ([pointer], None),
        'CFPreferencesSetAppValue': ([pointer, pointer, pointer], None),
        'CFPreferencesAppSynchronize': ([pointer], boolean),
        'CFPreferencesCopyAppValue': ([pointer, pointer], pointer),
    }
    for name, (arguments, result) in signatures.items():
        function = getattr(core, name)
        function.argtypes, function.restype = arguments, result
    held = []
    def string(text):
        data = text.encode()
        require(len(data) <= 4096 and '\0' not in text, 'Unbounded preference string')
        reference = core.CFStringCreateWithBytes(None, data, len(data), 0x08000100, 0)
        require(reference, 'Preference string allocation failed')
        held.append(reference)
        return reference
    try:
        key, domain = string(KEY), string('com.pulkit.edith')
        replacement = string(value) if value is not None else None
        core.CFPreferencesSetAppValue(key, replacement, domain)
        require(core.CFPreferencesAppSynchronize(domain), 'Preference cache synchronization failed')
        actual = core.CFPreferencesCopyAppValue(key, domain)
        if actual is None:
            return None
        held.append(actual)
        require(core.CFGetTypeID(actual) == core.CFStringGetTypeID(), 'Preference cache value is not a string')
        buffer = ctypes.create_string_buffer(4097)
        require(core.CFStringGetCString(actual, buffer, len(buffer), 0x08000100), 'Preference cache readback exceeds bound')
        return buffer.value.decode('utf8')
    finally:
        for reference in reversed(held):
            core.CFRelease(reference)


if __name__ == '__main__':
    require(len(sys.argv) == 5 and sys.argv[1] in ('setup', 'restore'), 'Invalid preference operation')
    hosted_account(sys.argv[2])
    print(json.dumps({'setup': setup, 'restore': restore}[sys.argv[1]](*sys.argv[2:], native_synchronize)))
