import importlib.util
import os
import stat
import subprocess
import sys
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


def driver_contract(developer):
    developer = watchdog.canonical_path(developer, directory=True)
    if developer.parts[-2:] != ("Contents", "Developer"):
        raise ValueError("Unexpected selected developer layout")
    toolchain = watchdog.canonical_path(
        developer / "Toolchains/XcodeDefault.xctoolchain", directory=True)
    directory = watchdog.canonical_path(toolchain / "usr/bin", directory=True)
    alias = directory / "swift"
    link = alias.lstat()
    if link.st_uid not in {0, os.getuid()} or link.st_nlink != 1:
        raise ValueError("Unexpected selected Swift driver ownership")
    if stat.S_ISLNK(link.st_mode):
        target_name = os.readlink(alias)
        if target_name not in {"swift-frontend", "swift-driver"}:
            raise ValueError("Unexpected selected Swift driver alias")
        target = watchdog.canonical_path(directory / target_name)
    else:
        target_name = None
        target = watchdog.canonical_path(alias)
    metadata = target.lstat()
    if metadata.st_nlink != 1:
        raise ValueError("Selected Swift driver must have one owned link")
    def identity(value):
        return tuple(getattr(value, name) for name in (
            "st_dev", "st_ino", "st_mode", "st_uid", "st_nlink", "st_size",
            "st_mtime_ns", "st_ctime_ns"))
    return alias, target, target_name, identity(link), identity(metadata)


class SelectedSwiftDriver:
    def __init__(self, developer):
        self.developer = Path(developer)
        self.contract = driver_contract(self.developer)

    def validate(self):
        if driver_contract(self.developer) != self.contract:
            raise ValueError("Selected Swift driver changed after admission")
        return self.contract[0]


def binary_directory(driver, check_output=subprocess.check_output):
    swift = driver.validate()
    result = check_output(
        [str(swift), "build", "--show-bin-path", "--package-path", "Packages/EdithHost",
         "--build-system", "native"], text=True, timeout=30).strip()
    driver.validate()
    return result


def main():
    if sys.argv[1:]:
        raise ValueError("Unexpected host test arguments")
    developer = subprocess.check_output(["xcode-select", "-p"], text=True, timeout=30).strip()
    driver = SelectedSwiftDriver(developer)
    directory = binary_directory(driver)
    execute(developer, directory, os.environ)


if __name__ == "__main__":
    main()
