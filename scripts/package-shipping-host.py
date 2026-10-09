import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

from verify_shipping_host import inspect_host, run

parser = argparse.ArgumentParser()
parser.add_argument('source', type=Path)
parser.add_argument('destination', type=Path)
parser.add_argument('--identity', required=True)
parser.add_argument('--slot')
parser.add_argument('--release', action='store_true')
args = parser.parse_args()
if args.release == bool(args.slot):
    parser.error('choose --release or --slot')
source = args.source.resolve()
destination = args.destination.resolve()
if source == destination or source in destination.parents or destination in source.parents:
    parser.error('source and destination must be separate bundles')
if destination == Path('/Applications/Edith.app'):
    parser.error('use build.sh --release --install for production installation')
inspect_host(source, launcher_required=False)
version = plistlib.loads(Path('Resources/Info.plist').read_bytes())
identifier = 'com.pulkit.edith' if args.release else f'com.pulkit.edith.dev.{args.slot}'
name = 'Edith' if args.release else f'Edith ({args.slot})'
runtime = ['--options', 'runtime', '--timestamp'] if 'Developer ID Application' in args.identity else []
with tempfile.TemporaryDirectory(prefix='edith-host-package-', dir=destination.parent if destination.parent.exists() else None) as temporary:
    temporary = Path(temporary)
    bundle = temporary / 'Edith.app'
    run('ditto', str(source), str(bundle))
    framework = bundle / 'Contents/Frameworks/Sparkle.framework'
    if (framework / 'Versions').is_dir():
        canonical = temporary / 'Sparkle.framework'
        shutil.copytree(framework, canonical, symlinks=False)
        shutil.rmtree(canonical / 'Versions')
        shutil.rmtree(framework)
        canonical.rename(framework)
    plist_path = bundle / 'Contents/Info.plist'
    plist = plistlib.loads(plist_path.read_bytes())
    plist.update({key: value for key, value in version.items() if key.startswith('NS') and key.endswith('UsageDescription')})
    plist.update(CFBundleIdentifier=identifier, CFBundleName=name, CFBundleDisplayName=name)
    for key in ('CFBundleShortVersionString', 'CFBundleVersion', 'SUFeedURL', 'SUPublicEDKey'):
        plist[key] = version[key]
    plist['SUEnableAutomaticChecks'] = args.release
    plist['SUAutomaticallyUpdate'] = args.release
    plist_path.write_bytes(plistlib.dumps(plist))
    resources = bundle / 'Contents/Resources'
    launcher = resources / 'ed-launcher'
    shutil.copyfile('Resources/ed-launcher', launcher)
    launcher.chmod(0o755)
    (bundle / 'Contents/MacOS/ed').symlink_to('../Resources/ed-launcher')
    for path in bundle.rglob('._*'):
        path.unlink()
    run('dot_clean', '-m', str(bundle))
    machos = [path for path in bundle.rglob('*') if path.is_file() and not path.is_symlink() and 'Mach-O' in run('file', '-b', str(path))]
    canonical_sparkle = '@rpath/Sparkle.framework/Sparkle'
    for path in machos:
        for line in run('otool', '-L', str(path)).splitlines()[1:]:
            dependency = line.strip().split(' ')[0]
            if '/Sparkle.framework/Versions/' in dependency and dependency.endswith('/Sparkle'):
                run('install_name_tool', '-change', dependency, canonical_sparkle, str(path))
        if path == framework / 'Sparkle':
            run('install_name_tool', '-id', canonical_sparkle, str(path))
    for path in machos:
        run('codesign', '--force', '--sign', args.identity, *runtime, '--preserve-metadata=entitlements', str(path))
    nested = sorted([path for path in bundle.rglob('*') if path.is_dir() and not path.is_symlink() and path.suffix in ('.framework', '.xpc', '.app')], key=lambda path: len(path.parts), reverse=True)
    for path in nested:
        run('codesign', '--force', '--sign', args.identity, *runtime, '--preserve-metadata=entitlements', str(path))
    entitlement_path = temporary / 'host.entitlements'
    inherited = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(source)], capture_output=True, check=True).stdout
    configured = Path(os.environ['EDITH_HOST_ENTITLEMENTS']).read_bytes() if os.environ.get('EDITH_HOST_ENTITLEMENTS') else inherited
    entitlements = plistlib.loads(configured) if configured.strip() else {}
    required = plistlib.loads(Path('Resources/Host.entitlements').read_bytes())
    entitlements.update(required)
    entitlement_path.write_bytes(plistlib.dumps(entitlements))
    entitlement_flags = ['--entitlements', str(entitlement_path)]
    requirement = []
    if args.identity != '-':
        details = run('codesign', '-dvv', str(bundle / 'Contents/MacOS/Edith'))
        team = next((line.split('=', 1)[1] for line in details.splitlines() if line.startswith('TeamIdentifier=')), '')
        if team and team != 'not set':
            requirement = ['--requirements', f'=designated => identifier "{identifier}" and anchor apple generic and certificate leaf[subject.OU] = "{team}"']
    run('codesign', '--force', '--sign', args.identity, *runtime, *entitlement_flags, *requirement, str(bundle))
    inspect_host(bundle, release=args.release)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        shutil.rmtree(destination)
    run('ditto', str(bundle), str(destination))
inspect_host(destination, release=args.release)
print(f'Packaged empty host: {name}, {plist["CFBundleShortVersionString"]}, no extension payloads')
