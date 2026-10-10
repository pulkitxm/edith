import json
import os
import subprocess
import sys
from pathlib import Path
import watchdog


def command(developer):
    return [str(Path(developer) / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift'),
            'test', '--package-path', 'Packages/ExtensionMarketplace', '--build-system',
            'native', '--jobs', '1']


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
    developer = watchdog.canonical_path(
        subprocess.check_output(['xcode-select', '-p'], text=True).strip(), directory=True)
    if developer.parts[-2:] != ('Contents', 'Developer'):
        raise ValueError('Unexpected selected developer layout')
    arguments = command(developer)
    watchdog.canonical_path(arguments[0])
    receipt = {'schema': 1, 'sourceCommit': source, 'passed': False}
    try:
        result = watchdog.run_batch('marketplace', arguments, directory, 900,
                                    environment=dict(os.environ), testing_process=is_testing_process)
        receipt['batch'] = result
        receipt['passed'] = passed(result)
    finally:
        (directory / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
