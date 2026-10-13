import ctypes
import hashlib
import importlib.util
import os
from pathlib import Path
import signal
import stat
import subprocess
import time


spec = importlib.util.spec_from_file_location(
    'selected_host_driver', Path(__file__).with_name('run-host-swift-testing.py'))
driver_runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver_runtime)
watchdog = driver_runtime.watchdog
PACKAGE = 'Extensions/database/DatabaseEngine'
FILTERS = {
    'database-mutation': 'mutationPreviewNormalizesWithoutExecuting',
    'database-executor': 'DatabaseExecutorTests',
}


def file_seal(path):
    path = watchdog.canonical_path(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                or before.st_uid not in {0, os.getuid()} or before.st_mode & 0o022
                or not before.st_mode & 0o111
                or before.st_size <= 0 or before.st_size > 536_870_912):
            raise ValueError('Invalid selected native test image')
        digest = hashlib.sha256()
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 65_536))
            if not chunk:
                raise ValueError('Truncated selected native test image')
            digest.update(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise ValueError('Selected native test image grew during admission')
        names = ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_nlink', 'st_size',
                 'st_mtime_ns', 'st_ctime_ns')
        identity = tuple(getattr(before, name) for name in names)
        if (identity != tuple(getattr(os.fstat(descriptor), name) for name in names)
                or identity != tuple(getattr(path.lstat(), name) for name in names)):
            raise ValueError('Selected native test image changed during admission')
        return identity, digest.hexdigest()
    finally:
        os.close(descriptor)


class DatabaseTestContract:
    def __init__(self, root, developer, binary_directory, environment, selection, deadline):
        if selection not in FILTERS:
            raise ValueError('Unknown selected Database test')
        self.root = watchdog.canonical_path(root, directory=True)
        self.deadline = deadline
        self.driver = driver_runtime.SelectedSwiftDriver(developer)
        self.helper, self.bundle, self.image, self.environment = watchdog.runtime_contract(
            developer, binary_directory, self.root / PACKAGE, environment,
            bundle_name='DatabaseEnginePackageTests')
        self.environment.pop('EDITH_DATABASE_POSTGRESQL_HOST', None)
        self.arguments = [str(self.helper), '--test-bundle-path', str(self.image), '--no-parallel',
                          '--filter', FILTERS[selection], '--testing-library', 'swift-testing']
        self.seals = {path: file_seal(path) for path in (self.helper, self.image)}

    def validate(self):
        if time.monotonic() >= self.deadline:
            raise TimeoutError('Selected Database test total deadline expired')
        self.driver.validate()
        watchdog.canonical_path(self.bundle, directory=True)
        if any(file_seal(path) != seal for path, seal in self.seals.items()):
            raise ValueError('Selected Database runtime changed after admission')
        if time.monotonic() >= self.deadline:
            raise TimeoutError('Selected Database test total deadline expired')

    def resume(self, process, ownership, current):
        self.validate()
        identity = ownership.known.get(process.pid)
        if (identity is None or identity not in current or identity[3] != str(self.helper)
                or identity[4] != process.pid or not ownership.verified(identity)):
            raise RuntimeError('Selected suspended testing identity did not match')
        info = watchdog.ProcessInfo()
        result = ownership.library.proc_pidinfo(
            process.pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
        if (result != ctypes.sizeof(info) or info.status != 4 or info.pid != process.pid
                or info.ppid != os.getpid() or info.uid != os.getuid() or info.ruid != os.getuid()
                or (info.pid, info.seconds, info.microseconds, info.pgid)
                != identity[:3] + identity[4:5]):
            raise RuntimeError('Selected testing process was not the owned suspended child')
        self.validate()
        if not ownership.verified(identity):
            raise RuntimeError('Selected testing identity changed before release')
        os.kill(process.pid, signal.SIGCONT)

    def launch(self, arguments, cwd, env, stdout, stderr, start_new_session):
        self.validate()
        if (arguments != self.arguments or Path(cwd) != self.root or env != self.environment
                or stderr != subprocess.STDOUT or start_new_session is not True):
            raise ValueError('Selected suspended testing launch changed')
        return SuspendedProcess(arguments, env, stdout.fileno(), self.root)


class SuspendedProcess:
    def __init__(self, arguments, environment, output, directory, library=None):
        self.returncode = None
        self.library = library or ctypes.CDLL(None, use_errno=True)
        self.pid = self.spawn(arguments, environment, output, directory)

    def spawn(self, arguments, environment, output, directory):
        library = self.library
        pointer = ctypes.POINTER(ctypes.c_void_p)
        specifications = {
            'posix_spawnattr_init': [pointer], 'posix_spawnattr_destroy': [pointer],
            'posix_spawnattr_setflags': [pointer, ctypes.c_short],
            'posix_spawnattr_setsigmask': [pointer, ctypes.POINTER(ctypes.c_uint32)],
            'posix_spawnattr_setsigdefault': [pointer, ctypes.POINTER(ctypes.c_uint32)],
            'posix_spawn_file_actions_init': [pointer], 'posix_spawn_file_actions_destroy': [pointer],
            'posix_spawn_file_actions_adddup2': [pointer, ctypes.c_int, ctypes.c_int],
            'posix_spawn_file_actions_addchdir_np': [pointer, ctypes.c_char_p],
            'posix_spawn': [ctypes.POINTER(ctypes.c_int), ctypes.c_char_p, pointer, pointer,
                            ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_char_p)],
        }
        for name, types in specifications.items():
            function = getattr(library, name)
            function.argtypes = types
            function.restype = ctypes.c_int
        def call(name, *values):
            code = getattr(library, name)(*values)
            if code:
                raise OSError(code, os.strerror(code))
        attributes, actions = ctypes.c_void_p(), ctypes.c_void_p()
        call('posix_spawnattr_init', ctypes.byref(attributes))
        actions_ready = False
        descriptor = None
        try:
            call('posix_spawn_file_actions_init', ctypes.byref(actions))
            actions_ready = True
            call('posix_spawn_file_actions_addchdir_np', ctypes.byref(actions), os.fsencode(directory))
            call('posix_spawnattr_setflags', ctypes.byref(attributes), 0x0080 | 0x0400 | 0x4000 | 0x0004 | 0x0008)
            mask = ctypes.c_uint32(0)
            defaults = ctypes.c_uint32(sum(1 << (int(value) - 1) for value in
                                         (signal.SIGPIPE, signal.SIGXFSZ)))
            call('posix_spawnattr_setsigmask', ctypes.byref(attributes), ctypes.byref(mask))
            call('posix_spawnattr_setsigdefault', ctypes.byref(attributes), ctypes.byref(defaults))
            descriptor = os.open('/dev/null', os.O_RDONLY | os.O_CLOEXEC)
            for source, target in ((descriptor, 0), (output, 1), (output, 2)):
                call('posix_spawn_file_actions_adddup2', ctypes.byref(actions), source, target)
            argv = (ctypes.c_char_p * (len(arguments) + 1))(
                *[os.fsencode(value) for value in arguments], None)
            values = [os.fsencode(key + '=' + value) for key, value in sorted(environment.items())]
            envp = (ctypes.c_char_p * (len(values) + 1))(*values, None)
            pid = ctypes.c_int()
            call('posix_spawn', ctypes.byref(pid), os.fsencode(arguments[0]),
                 ctypes.byref(actions), ctypes.byref(attributes), argv, envp)
            if pid.value <= 0:
                raise RuntimeError('Invalid owned suspended child identifier')
            return pid.value
        finally:
            if descriptor is not None:
                os.close(descriptor)
            if actions_ready:
                library.posix_spawn_file_actions_destroy(ctypes.byref(actions))
            library.posix_spawnattr_destroy(ctypes.byref(attributes))

    def poll(self):
        if self.returncode is None:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.returncode = os.waitstatus_to_exitcode(status)
        return self.returncode

    def wait(self, timeout):
        deadline = time.monotonic() + timeout
        while self.poll() is None:
            if time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired('selected Database test', timeout)
            time.sleep(0.01)
        return self.returncode

    def abort_suspended(self):
        if self.poll() is None:
            os.kill(self.pid, signal.SIGKILL)
        self.wait(timeout=5)


def build_arguments(root, developer):
    driver = driver_runtime.SelectedSwiftDriver(developer)
    return driver, [str(driver.validate()), 'build', '--build-tests', '--package-path',
                    str(Path(root) / PACKAGE), '--jobs', '1']


def binary_directory(driver, root, environment, timeout, check_output=subprocess.check_output):
    result = check_output(
        [str(driver.validate()), 'build', '--show-bin-path', '--package-path', str(Path(root) / PACKAGE),
         '--jobs', '1'], text=True, timeout=timeout, env=environment).strip()
    driver.validate()
    return result
