import os
import pathlib
import plistlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
production = 'com.pulkit.edith'
prefix = production + '.dev.'


def read(relative):
    return plistlib.loads((root / relative).read_bytes())


main = read('Contents/Info.plist')
identifier = main['CFBundleIdentifier']
development = identifier != production
slot = identifier[len(prefix):] if development else ''
assert not development or (identifier.startswith(prefix) and slot), identifier
helper = read('Contents/Library/LoginItems/Edith.app/Contents/Info.plist')
assert helper['CFBundleIdentifier'] == identifier + ('.helper' if development else '.helper.v2')
assert main['CFBundleDisplayName'] == (f'Edith ({slot})' if development else 'Edith')
assert helper['CFBundleDisplayName'] == (f'Edith ({slot}) Menu Bar' if development else 'Edith Menu Bar')
agent = identifier + '.agent'
launch = read('Contents/Library/LaunchAgents/' + agent + '.plist')
assert launch['Label'] == agent
assert launch['MachServices'] == {agent: True}
assert launch['ProcessType'] == 'Adaptive', launch.get('ProcessType')
if development:
    program = [os.path.realpath(p) for p in launch['ProgramArguments']]
    assert program == [os.path.realpath(root / 'Contents/MacOS/edithd')], program
    assert not {'BundleProgram', 'KeepAlive', 'AssociatedBundleIdentifiers'} & launch.keys()
else:
    assert launch['BundleProgram'] == 'Contents/MacOS/edithd'
    assert launch['AssociatedBundleIdentifiers'] == [identifier]
signature = subprocess.run(
    ['codesign', '-dvv', str(root / 'Contents/MacOS/edithd')],
    capture_output=True, text=True, check=True)
assert 'Identifier=' + agent in signature.stderr.splitlines()
print('Application, menu helper, and daemon identities match: ' + identifier)
