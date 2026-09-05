import argparse
import ctypes
import dataclasses
import fcntl
import os
from pathlib import Path
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time

from edith_fixture_copy import copy_fixture_file


BSD_INFO = struct.Struct('=12I16s32s5Ii2Q')
EXECUTABLES = (
    Path('Contents/MacOS/Edith'),
    Path('Contents/Library/LoginItems/Edith.app/Contents/MacOS/Edith'),
    Path('Contents/MacOS/edithd'),
)


@dataclasses.dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    started: tuple
    executable: tuple
    path: Path = dataclasses.field(compare=False)


class NativeProcesses:
    def __init__(self):
        self.library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.library.proc_pidinfo.argtypes = (
            ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int)
        self.library.proc_pidpath.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32)

    def process_info(self, pid):
        info = ctypes.create_string_buffer(BSD_INFO.size)
        if self.library.proc_pidinfo(pid, 3, 0, info, len(info)) != len(info):
            return None
        return BSD_INFO.unpack(info.raw)

    def identity(self, pid):
        fields = self.process_info(pid)
        if fields is None:
            return None
        if fields[5] != os.getuid() or fields[1] == 5:
            return None
        path = ctypes.create_string_buffer(4096)
        if self.library.proc_pidpath(pid, path, len(path)) <= 0:
            return None
        try:
            resolved = Path(os.fsdecode(path.value)).resolve(strict=True)
            executable = file_identity(resolved)
        except OSError:
            return None
        return ProcessIdentity(pid, fields[-2:], executable, resolved)

    def matching(self, executables):
        result = subprocess.run(['/bin/ps', '-axo', 'pid='], check=True,
                                capture_output=True, text=True, timeout=5)
        identities = []
        for value in result.stdout.split():
            identity = self.identity(int(value))
            if identity and executables.get(identity.path) == identity.executable:
                identities.append(identity)
        return identities

    def alive(self, identity):
        fields = self.process_info(identity.pid)
        if fields is not None:
            return fields[1] != 5 and fields[-2:] == identity.started
        try:
            os.kill(identity.pid, 0)
            return True
        except ProcessLookupError:
            return False

    def stop(self, identities, timeout=5):
        self.send(identities, signal.SIGTERM)
        remaining = self.wait(identities, timeout)
        self.send(remaining, signal.SIGKILL)
        if self.wait(remaining, 2):
            raise RuntimeError('Installed processes did not exit; replacement retained for recovery.')

    def send(self, identities, value):
        for identity in identities:
            if self.identity(identity.pid) == identity:
                try:
                    os.kill(identity.pid, value)
                except ProcessLookupError:
                    pass

    def wait(self, identities, timeout):
        deadline = time.monotonic() + timeout
        while True:
            remaining = [identity for identity in identities if self.alive(identity)]
            if not remaining or time.monotonic() >= deadline:
                return remaining
            time.sleep(0.05)


def file_identity(path):
    value = path.stat()
    return value.st_dev, value.st_ino


def existing_identity(path):
    try:
        return file_identity(path)
    except FileNotFoundError:
        return None


def verify_bundle(path):
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(path)],
                   check=True, timeout=120)
    for relative in EXECUTABLES:
        executable = path / relative
        if not stat.S_ISREG(executable.stat().st_mode) or not os.access(executable, os.X_OK):
            raise RuntimeError(f'Staged executable is invalid: {relative}')


def request_quit(destination, identities, processes):
    if not identities:
        return
    quoted = str(destination).replace('\\', '\\\\').replace('"', '\\"')
    subprocess.run(['/usr/bin/osascript', '-e', f'tell application "{quoted}" to quit'],
                   check=True, capture_output=True, timeout=30)
    if processes.wait(identities, 10):
        raise RuntimeError('Edith did not quit. Resolve unsaved work and retry installation.')


def exchange(source, destination, replacing):
    library = ctypes.CDLL(None, use_errno=True)
    function = library.renamex_np
    function.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    function.restype = ctypes.c_int
    if function(os.fsencode(source), os.fsencode(destination), 2 if replacing else 4) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def install(source, destination, quit_application=request_quit, verify=verify_bundle):
    if sys.platform != 'darwin':
        raise RuntimeError('Application installation requires macOS.')
    source = source.resolve(strict=True)
    destination = destination.absolute()
    if not source.is_dir() or destination.is_symlink():
        raise ValueError('Installation requires ordinary application directories.')
    if destination.exists() and not destination.is_dir():
        raise ValueError('The installed application is not a directory.')
    destination = destination.parent.resolve(strict=True) / destination.name
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError('The build and installed application must be separate directories.')
    lock = destination.parent / f'.{destination.name}.install.lock'
    descriptor = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return install_locked(source, destination, quit_application, verify)
    finally:
        os.close(descriptor)


def install_locked(source, destination, quit_application, verify):
    original = existing_identity(destination)
    temporary = Path(tempfile.mkdtemp(prefix=f'.{destination.name}.install-', dir=destination.parent))
    staged = temporary / destination.name
    published = False
    completed = False
    try:
        shutil.copytree(source, staged, symlinks=True, copy_function=copy_fixture_file)
        verify(staged)
        if existing_identity(destination) != original:
            raise RuntimeError('The installed application changed while staging; retry installation.')
        processes = NativeProcesses()
        installed_files = {destination / relative: identity for relative in EXECUTABLES
                           if (identity := existing_identity(destination / relative)) is not None}
        main_path = destination / EXECUTABLES[0]
        quit_application(destination, processes.matching(
            {main_path: installed_files.get(main_path)}), processes)
        retired_processes = processes.matching(installed_files)
        if existing_identity(destination) != original:
            raise RuntimeError('The installed application changed before publication; retry installation.')
        exchange(staged, destination, replacing=original is not None)
        published = True
        retired_files = {staged / path.relative_to(destination): identity
                         for path, identity in installed_files.items()}
        processes.stop(retired_processes)
        processes.stop(processes.matching(retired_files))
        completed = True
    finally:
        if not published or completed:
            shutil.rmtree(temporary)
        else:
            print(f'Retired application preserved at {staged}', file=sys.stderr)
    return destination


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    arguments = parser.parse_args()
    print(f'Installed {install(arguments.source, arguments.destination)}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Installation stopped: {error}', file=sys.stderr)
        sys.exit(1)
