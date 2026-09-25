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
camera_identifier = identifier + '.camera'
camera_root = root / 'Contents/Library/SystemExtensions' / (camera_identifier + '.systemextension')
camera = plistlib.loads((camera_root / 'Contents/Info.plist').read_bytes())
assert camera['CFBundleIdentifier'] == camera_identifier, camera['CFBundleIdentifier']
assert camera['CFBundleExecutable'] == camera_identifier
assert camera['CFBundlePackageType'] == 'SYSX'
assert camera['CFBundleVersion'] == main['CFBundleVersion']
assert camera['CFBundleDisplayName'] == (f'Edith Camera ({slot})' if development else 'Edith Camera')
assert (camera_root / 'Contents/MacOS' / camera_identifier).is_file()
service = camera['CMIOExtension']['CMIOExtensionMachServiceName']
assert service == camera_identifier or service.endswith('.' + camera_identifier), service
entitlements = subprocess.run(
    ['codesign', '-d', '--entitlements', '-', '--xml', str(camera_root)],
    capture_output=True, check=True).stdout
granted = plistlib.loads(entitlements) if entitlements.strip() else {}
assert granted.get('com.apple.security.app-sandbox') is True, granted
if service != camera_identifier:
    assert granted.get('com.apple.security.application-groups') == [service], granted
print('Application, menu helper, camera, and daemon identities match: ' + identifier)
