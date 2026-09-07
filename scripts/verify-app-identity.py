import pathlib
import plistlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])


def read(relative):
    return plistlib.loads((root / relative).read_bytes())


main = read('Contents/Info.plist')
identifier = main['CFBundleIdentifier']
assert identifier in ('com.pulkit.edith', 'com.pulkit.edith.development')
development = identifier.endswith('.development')
helper = read('Contents/Library/LoginItems/Edith.app/Contents/Info.plist')
assert helper['CFBundleIdentifier'] == identifier + ('.helper' if development else '.helper.v2')
assert main['CFBundleDisplayName'] == ('Edith Development' if development else 'Edith')
assert helper['CFBundleDisplayName'] == ('Edith Development Menu Bar' if development else 'Edith Menu Bar')
agent = identifier + '.agent'
launch = read('Contents/Library/LaunchAgents/' + agent + '.plist')
assert launch['Label'] == agent
assert launch['MachServices'] == {agent: True}
assert launch['BundleProgram'] == 'Contents/MacOS/edithd'
assert launch['AssociatedBundleIdentifiers'] == [identifier]
signature = subprocess.run(
    ['codesign', '-dvv', str(root / 'Contents/MacOS/edithd')],
    capture_output=True, text=True, check=True)
assert 'Identifier=' + agent in signature.stderr.splitlines()
print('Application, menu helper, and daemon identities match: ' + identifier)
