import json
import os
import subprocess
import sys
from pathlib import Path
import watchdog


def command(developer, entry=None, show_bin=False):
    arguments = [str(entry or Path(developer) / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-build'),
                 '--package-path', 'Packages/ExtensionMarketplace', '--build-system', 'native', '--jobs', '1']
    return arguments + (['--show-bin-path'] if show_bin else ['--build-tests'])


def runtime_contract(developer, binary_directory, environment):
    package = watchdog.canonical_path(Path('Packages/ExtensionMarketplace').resolve(), directory=True)
    binary = watchdog.canonical_path(binary_directory, directory=True)
    build = watchdog.canonical_path(package / '.build', directory=True)
    if not binary.is_relative_to(build):
        raise ValueError('Marketplace executable outside its owning build directory')
    bundle = watchdog.canonical_path(binary / 'ExtensionMarketplacePackageTests.xctest', directory=True)
    executable = watchdog.canonical_path(bundle / 'Contents/MacOS/ExtensionMarketplacePackageTests')
    toolchain = watchdog.canonical_path(Path(developer) / 'Toolchains/XcodeDefault.xctoolchain', directory=True)
    helper = watchdog.canonical_path(toolchain / 'usr/libexec/swift/pm/swiftpm-testing-helper')
    platform = watchdog.canonical_path(Path(developer) / 'Platforms/MacOSX.platform', directory=True)
    frameworks = [watchdog.canonical_path(platform / 'Developer/Library' / name, directory=True)
                  for name in ['Frameworks', 'PrivateFrameworks']]
    libraries = [watchdog.canonical_path(platform / 'Developer/usr/lib', directory=True)]
    testing = toolchain / 'usr/lib/swift/macosx/testing'
    if testing.exists():
        libraries.insert(0, watchdog.canonical_path(testing, directory=True))
    result = dict(environment, NO_COLOR='1', DEVELOPER_DIR=str(developer))
    for key, paths in [('DYLD_FRAMEWORK_PATH', frameworks), ('DYLD_LIBRARY_PATH', libraries)]:
        result[key] = ':'.join(str(path) for path in paths)
    return helper, executable, result


def test_command(helper, executable):
    image = Path(executable)
    if not image.is_absolute() or '..' in image.parts or image.parts[-4:] != (
            'ExtensionMarketplacePackageTests.xctest', 'Contents', 'MacOS', 'ExtensionMarketplacePackageTests'):
        raise ValueError('Marketplace test image must remain inside its owning bundle')
    return [str(helper), '--test-bundle-path', str(executable), 'test', '--skip-build',
            '--no-parallel', '--package-path', 'Packages/ExtensionMarketplace',
            '--build-system', 'native', '--jobs', '1', str(executable),
            '--testing-library', 'swift-testing']


def executable_identity(executable):
    metadata = watchdog.canonical_path(executable).stat()
    return tuple(getattr(metadata, key) for key in ['st_dev', 'st_ino', 'st_uid', 'st_mode',
                                                  'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns'])


def helper_process_factory(helper, executable, process_factory=subprocess.Popen):
    identity = executable_identity(helper)
    image_identity = executable_identity(executable)
    expected = test_command(helper, executable)

    def launch(arguments, **options):
        if arguments != expected or executable_identity(helper) != identity or executable_identity(executable) != image_identity:
            raise ValueError('Selected Marketplace helper changed before launch')
        return process_factory(arguments, **options)
    return launch


def swift_contract(developer, entry):
    toolchain = watchdog.canonical_path(
        Path(developer) / 'Toolchains/XcodeDefault.xctoolchain', directory=True)
    entry = Path(entry)
    if not entry.is_absolute() or '..' in entry.parts or entry != toolchain / 'usr/bin/swift-build':
        raise ValueError('Unexpected selected Swift entry')
    executable = entry.resolve(strict=True)
    if not executable.is_relative_to(toolchain):
        raise ValueError('Selected Swift escapes its toolchain')
    watchdog.canonical_path(executable)
    metadata = executable.stat()
    return {'entry': str(entry), 'executable': str(executable),
            'identity': {key: getattr(metadata, key) for key in
                         ['st_dev', 'st_ino', 'st_uid', 'st_mode', 'st_nlink', 'st_size',
                          'st_mtime_ns', 'st_ctime_ns']}}


def swift_process_factory(developer, contract, process_factory=subprocess.Popen):
    def launch(arguments, **options):
        if arguments[0] != contract['entry'] or swift_contract(developer, arguments[0]) != contract:
            raise ValueError('Selected Swift identity changed before launch')
        return process_factory(arguments, executable=contract['executable'], **options)
    return launch


def is_testing_process(path):
    return Path(path).name in {'swiftpm-testing', 'swiftpm-testing-helper',
                               'ExtensionMarketplacePackageTests'}


def passed(result):
    return (result['exitCode'] == 0 and result['testsCompleted']
            and result['observedTestingProcess'] and not result['timedOut']
            and result['remainingOwnedProcesses'] == 0
            and result['unverifiedOwnedProcesses'] == 0 and not result.get('retirementFailed', False))


def main():
    if sys.argv[1:]:
        raise ValueError('Unexpected Marketplace diagnostic arguments')
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    watchdog.admit(os.environ, source)
    directory = Path('local/hosted-marketplace-tests')
    directory.mkdir(parents=True, exist_ok=False, mode=0o700)
    receipt = {'schema': 1, 'sourceCommit': source, 'passed': False, 'batches': []}
    try:
        developer = watchdog.canonical_path(
            subprocess.check_output(['xcode-select', '-p'], text=True).strip(), directory=True)
        if developer.parts[-2:] != ('Contents', 'Developer'):
            raise ValueError('Unexpected selected developer layout')
        entry = subprocess.check_output(
            ['xcrun', '--toolchain', 'XcodeDefault', '--find', 'swift-build'], text=True,
            env={**os.environ, 'DEVELOPER_DIR': str(developer)}, timeout=30).strip()
        selected = swift_contract(developer, entry)
        receipt['selectedSwift'] = selected
        build = watchdog.run_batch('build', command(developer, entry), directory, 600,
                                   environment=dict(os.environ, DEVELOPER_DIR=str(developer)),
                                   process_factory=swift_process_factory(developer, selected))
        receipt['batches'].append(build)
        if build['exitCode'] != 0 or build['timedOut'] or build['remainingOwnedProcesses'] != 0 or build['unverifiedOwnedProcesses'] != 0 or build.get('retirementFailed', False):
            return 1
        if swift_contract(developer, entry) != selected:
            raise ValueError('Selected build tool changed before product lookup')
        binary = subprocess.check_output(command(developer, entry, show_bin=True),
                                         executable=selected['executable'], env=dict(os.environ, DEVELOPER_DIR=str(developer)), text=True, timeout=30).strip()
        helper, executable, environment = runtime_contract(developer, binary, os.environ)
        receipt['runtime'] = {'helper': str(helper), 'executable': str(executable)}
        result = watchdog.run_batch('marketplace', test_command(helper, executable), directory, 900,
                                    environment=environment, testing_process=is_testing_process,
                                    process_factory=helper_process_factory(helper, executable))
        receipt['batches'].append(result)
        receipt['passed'] = passed(result)
    except Exception as error:
        receipt['failureCategory'] = type(error).__name__
        raise
    finally:
        (directory / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
