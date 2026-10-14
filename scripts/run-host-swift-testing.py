import importlib.util
import hashlib
import os
import stat
import subprocess
import sys
import weakref
from pathlib import Path


spec = importlib.util.spec_from_file_location(
    "host_test_runtime", Path(__file__).parent / "hosted-host-tests/watchdog.py")
watchdog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watchdog)


def invocation(developer, binary_directory, environment):
    helper, _, executable, runtime_environment = watchdog.runtime_contract(
        developer, binary_directory, Path("Packages/EdithHost").resolve(), environment)
    arguments = watchdog.command("core", developer, helper, executable)
    index = arguments.index("--filter")
    del arguments[index:index + 2]
    return arguments, runtime_environment


def execute(developer, binary_directory, environment, run=subprocess.run):
    arguments, runtime_environment = invocation(developer, binary_directory, environment)
    run(arguments, env=runtime_environment, check=True)


def driver_contract(developer, entry="swift", inspect=lambda path: path.lstat()):
    targets = {"swift": {"swift-frontend", "swift-driver"}, "swift-test": {"swift-package"}, "swift-build": {"swift-package"}}
    if entry not in targets:
        raise ValueError("Unexpected selected Swift entry")
    developer = watchdog.canonical_path(developer, directory=True)
    if developer.parts[-2:] != ("Contents", "Developer"):
        raise ValueError("Unexpected selected developer layout")
    toolchain = watchdog.canonical_path(
        developer / "Toolchains/XcodeDefault.xctoolchain", directory=True)
    directory = watchdog.canonical_path(toolchain / "usr/bin", directory=True)
    alias = directory / entry
    link = inspect(alias)
    if link.st_uid not in {0, os.getuid()} or link.st_nlink != 1:
        raise ValueError("Unexpected selected Swift driver ownership")
    if stat.S_ISLNK(link.st_mode):
        target_name = os.readlink(alias)
        if target_name not in targets[entry]:
            raise ValueError("Unexpected selected Swift driver alias")
        target = watchdog.canonical_path(directory / target_name)
    else:
        if entry in {"swift-test", "swift-build"}:
            raise ValueError("Selected Swift package entry must use its package alias")
        target_name = None
        target = watchdog.canonical_path(alias)
    metadata = inspect(target)
    if metadata.st_nlink != 1:
        raise ValueError("Selected Swift driver must have one owned link")
    if entry in {"swift-test", "swift-build"}:
        directory_info = inspect(directory)
        if (directory_info.st_uid != 0 or directory_info.st_mode & 0o022
                or link.st_uid != 0 or metadata.st_uid != 0 or metadata.st_mode & 0o022):
            raise ValueError("Selected Swift package entry must be immutable and owned")
    def identity(value):
        return tuple(getattr(value, name) for name in (
            "st_dev", "st_ino", "st_mode", "st_uid", "st_nlink", "st_size",
            "st_mtime_ns", "st_ctime_ns"))
    return alias, target, target_name, identity(link), identity(metadata)


class SelectedSwiftDriver:
    def __init__(self, developer, entry="swift", inspect=lambda path: path.lstat()):
        self.developer = Path(developer)
        self.entry = entry
        self.inspect = inspect
        self.contract = driver_contract(self.developer, entry, inspect)

    def validate(self):
        if driver_contract(self.developer, self.entry, self.inspect) != self.contract:
            raise ValueError("Selected Swift driver changed after admission")
        return self.contract[0]


ADMITTED_PACKAGE_DRIVER_PAIRS = weakref.WeakSet()
PACKAGE_IMAGE_BOUND = 268_435_456


class SelectedPackageArguments(list):
    def __init__(self, driver, arguments):
        super().__init__(arguments)
        self.driver = driver


def image_identity(value):
    return tuple(getattr(value, name) for name in (
        "st_dev", "st_ino", "st_mode", "st_uid", "st_nlink", "st_size",
        "st_mtime_ns", "st_ctime_ns"))


class SelectedPackageDriverPair:
    def __init__(self, driver):
        self.images = []
        try:
            if type(driver) is not SelectedSwiftDriver or driver.entry not in {"swift-test", "swift-build"}:
                raise ValueError("Selected package driver required")
            driver.validate()
            self.driver = driver
            self.source = driver.contract[1]
            self.directory = self.source.parent
            self.destination = self.directory / "swift-driver"
            directory = self.directory.lstat()
            if (self.source.name != "swift-package" or not stat.S_ISDIR(directory.st_mode)
                    or directory.st_uid != 0 or directory.st_mode & 0o022):
                raise ValueError("Immutable selected package directory required")
            self.directory_identity = image_identity(directory)
            for path in (self.source, self.destination):
                if path.resolve(strict=True) != path:
                    raise ValueError("Canonical selected package image required")
                descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
                self.images.append((path, descriptor, None, None))
                value = os.fstat(descriptor)
                if (not stat.S_ISREG(value.st_mode) or value.st_uid != 0
                        or value.st_nlink != 1 or value.st_mode & 0o022
                        or not value.st_mode & 0o111 or not 0 < value.st_size <= PACKAGE_IMAGE_BOUND):
                    raise ValueError("Immutable selected package image required")
                identity = image_identity(value)
                digest = self.image_digest(descriptor, value.st_size)
                self.images[-1] = (path, descriptor, identity, digest)
            if self.images[0][2] != driver.contract[4]:
                raise ValueError("Selected package image differs from alias contract")
            self.validate_images()
            ADMITTED_PACKAGE_DRIVER_PAIRS.add(self)
        except BaseException:
            self.close()
            raise

    @staticmethod
    def image_digest(descriptor, size):
        digest = hashlib.sha256()
        offset = 0
        while offset < size:
            block = os.pread(descriptor, min(1_048_576, size - offset), offset)
            if not block:
                raise RuntimeError("Incomplete selected package image")
            offset += len(block)
            digest.update(block)
        return digest.hexdigest()

    def validate_images(self):
        self.driver.validate()
        if (self.directory.resolve(strict=True) != self.directory
                or image_identity(self.directory.lstat()) != self.directory_identity):
            raise RuntimeError("Selected package directory changed")
        for path, descriptor, identity, digest in self.images:
            if (path.resolve(strict=True) != path or image_identity(path.lstat()) != identity
                    or image_identity(os.fstat(descriptor)) != identity
                    or self.image_digest(descriptor, identity[5]) != digest
                    or image_identity(path.lstat()) != identity
                    or image_identity(os.fstat(descriptor)) != identity):
                raise RuntimeError("Selected package image changed")

    def permits(self, previous, current):
        if not admitted_package_driver_pair(self) or (previous, current) != (str(self.source), str(self.destination)):
            return False
        self.validate_images()
        return True

    def close(self):
        ADMITTED_PACKAGE_DRIVER_PAIRS.discard(self)
        for _, descriptor, _, _ in self.images:
            os.close(descriptor)
        self.images = []

    def __del__(self):
        if getattr(self, "images", None):
            self.close()


def admitted_package_driver_pair(value):
    return type(value) is SelectedPackageDriverPair and value in ADMITTED_PACKAGE_DRIVER_PAIRS


def binary_directory(driver, check_output=subprocess.check_output):
    swift = driver.validate()
    result = check_output(
        [str(swift), "build", "--show-bin-path", "--package-path", "Packages/EdithHost",
         "--build-system", "native"], text=True, timeout=30).strip()
    driver.validate()
    return result


def run_package_tests(developer, arguments, run=subprocess.run):
    if not arguments or arguments[0] == "test":
        raise ValueError("Unexpected package test arguments")
    driver = SelectedSwiftDriver(developer, entry="swift-test")
    try:
        result = run([str(driver.validate()), *arguments], check=False)
    finally:
        driver.validate()
    return result.returncode


def main():
    arguments = sys.argv[1:]
    if arguments:
        if arguments[0] != "package-test":
            raise ValueError("Unexpected host test arguments")
        return run_package_tests(os.environ["DEVELOPER_DIR"], arguments[1:], run=subprocess.run)
    developer = subprocess.check_output(["xcode-select", "-p"], text=True, timeout=30).strip()
    driver = SelectedSwiftDriver(developer)
    directory = binary_directory(driver)
    execute(developer, directory, os.environ)


if __name__ == "__main__":
    sys.exit(main())
