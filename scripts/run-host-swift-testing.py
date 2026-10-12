import importlib.util
import os
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


def main():
    if sys.argv[1:]:
        raise ValueError("Unexpected host test arguments")
    developer = subprocess.check_output(["xcode-select", "-p"], text=True, timeout=30).strip()
    swift = watchdog.canonical_path(
        Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
    binary_directory = subprocess.check_output(
        [str(swift), "build", "--show-bin-path", "--package-path", "Packages/EdithHost",
         "--build-system", "native"], text=True, timeout=30).strip()
    execute(developer, binary_directory, os.environ)


if __name__ == "__main__":
    main()
