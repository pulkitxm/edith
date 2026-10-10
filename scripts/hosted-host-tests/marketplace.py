import json
import os
import subprocess
import sys
from pathlib import Path
import watchdog


def command(developer, entry=None):
    return [str(entry or Path(developer) / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'),
            'test', '--package-path', 'Packages/ExtensionMarketplace', '--build-system',
            'native', '--jobs', '1']


def swift_contract(developer, entry):
    toolchain = watchdog.canonical_path(
        Path(developer) / 'Toolchains/XcodeDefault.xctoolchain', directory=True)
    entry = Path(entry)
    if not entry.is_absolute() or '..' in entry.parts or entry != toolchain / 'usr/bin/swift':
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
            and result['unverifiedOwnedProcesses'] == 0)


def main():
    if sys.argv[1:]:
        raise ValueError('Unexpected Marketplace diagnostic arguments')
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    watchdog.admit(os.environ, source)
    directory = Path('local/hosted-marketplace-tests')
    directory.mkdir(parents=True, exist_ok=False, mode=0o700)
    receipt = {'schema': 1, 'sourceCommit': source, 'passed': False}
    try:
        developer = watchdog.canonical_path(
            subprocess.check_output(['xcode-select', '-p'], text=True).strip(), directory=True)
        if developer.parts[-2:] != ('Contents', 'Developer'):
            raise ValueError('Unexpected selected developer layout')
        entry = subprocess.check_output(
            ['xcrun', '--toolchain', 'XcodeDefault', '--find', 'swift'], text=True,
            env={**os.environ, 'DEVELOPER_DIR': str(developer)}, timeout=30).strip()
        selected = swift_contract(developer, entry)
        receipt['selectedSwift'] = selected
        arguments = command(developer, entry)
        result = watchdog.run_batch('marketplace', arguments, directory, 900,
                                    environment=dict(os.environ), testing_process=is_testing_process,
                                    process_factory=swift_process_factory(developer, selected))
        receipt['batch'] = result
        receipt['passed'] = passed(result)
    finally:
        (directory / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
