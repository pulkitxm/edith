import json
from pathlib import Path
import plistlib
import re
import subprocess


def run(*arguments):
    result = subprocess.run(arguments, capture_output=True, text=True, check=True)
    return result.stdout + result.stderr


def extension_point_descriptor(identifier):
    return {
        'EXVersion': 1,
        identifier + '.ExtensionUI': {
            'EXExtensionPointIsPublic': True,
            'EXExtensionPointName': 'ExtensionUI',
            'EXPresentsUserInterface': True,
            'EXRequiredEntitlements': {'com.apple.security.app-sandbox': True},
            'EXRequiresEnhancedSecurity': False,
            'EXSupportedPlatforms': ['macOS'],
            '_EXScopeRestriction': 'none',
        },
    }


def inspect_layout(bundle, release=False, launcher_required=True):
    bundle = Path(bundle).resolve()
    plist = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    identifier = plist['CFBundleIdentifier']
    assert identifier == 'com.pulkit.edith' or identifier.startswith('com.pulkit.edith.dev.'), identifier
    if release:
        assert identifier == 'com.pulkit.edith', identifier
    name = 'Edith' if identifier == 'com.pulkit.edith' else f'Edith ({identifier.removeprefix("com.pulkit.edith.dev.")})'
    assert plist['CFBundleDisplayName'] == name, plist['CFBundleDisplayName']
    assert plist['CFBundleExecutable'] == 'Edith'
    assert plist['SUPublicEDKey'] and plist['SUFeedURL'].startswith('https://github.com/pulkitxm/edith/releases/')
    executable = bundle / 'Contents/MacOS/Edith'
    assert executable.is_file() and not executable.is_symlink()
    allowed = {'Info.plist', 'MacOS', 'Frameworks', 'Resources', '_CodeSignature', 'Library', 'Extensions'}
    assert {path.name for path in (bundle / 'Contents').iterdir()} <= allowed, 'Unexpected host payload directory'
    extensions = bundle / 'Contents/Extensions'
    assert {path.name for path in extensions.iterdir()} == {'ExtensionUI.appextensionpoints'}, 'Feature payload in host Extensions'
    descriptor = extensions / 'ExtensionUI.appextensionpoints'
    assert descriptor.is_file() and not descriptor.is_symlink(), 'Invalid host extension point file'
    assert plistlib.loads(descriptor.read_bytes()) == extension_point_descriptor(identifier), 'Host extension point identity does not match its bundle'
    library = bundle / 'Contents/Library'
    label = 'com.pulkit.edith.extensions.carrier.v1'
    assert {path.name for path in library.iterdir()} == {'LaunchDaemons'}, 'Feature payload in host Library'
    daemons = library / 'LaunchDaemons'
    assert {path.name for path in daemons.iterdir()} == {label + '.plist'}, 'Unexpected host daemon'
    daemon = plistlib.loads((daemons / (label + '.plist')).read_bytes())
    assert daemon == {'Label': label, 'BundleProgram': 'Contents/MacOS/Edith', 'ProgramArguments': ['Edith', '--extension-carrier'], 'MachServices': {label: True}}, 'Invalid generic host daemon'
    assert {path.name for path in (bundle / 'Contents/MacOS').iterdir()} == ({'Edith', 'ed'} if launcher_required else {'Edith'}), 'Unexpected host executable'
    assert {path.name for path in (bundle / 'Contents/Frameworks').iterdir()} == {'Sparkle.framework'}, 'Feature framework in host'
    resources = {'AppIcon.icns', 'index.json', 'ed-launcher'} if launcher_required else {'AppIcon.icns', 'index.json'}
    assert {path.name for path in (bundle / 'Contents/Resources').iterdir()} == resources, 'Feature resources in host'
    if launcher_required:
        launcher = bundle / 'Contents/MacOS/ed'
        assert launcher.is_symlink() and launcher.readlink() == Path('../Resources/ed-launcher')
        assert (bundle / 'Contents/Resources/ed-launcher').read_text().startswith('#!/bin/sh\n')
    return plist


def inspect_host(bundle, release=False, launcher_required=True):
    bundle = Path(bundle).resolve()
    plist = inspect_layout(bundle, release=release, launcher_required=launcher_required)
    executable = bundle / 'Contents/MacOS/Edith'
    bytes_installed = 0
    binaries = []
    for path in bundle.rglob('*'):
        if path.is_symlink():
            assert path.resolve().is_relative_to(bundle) and path.resolve().exists(), f'Invalid bundle link: {path.name}'
            continue
        if not path.is_file():
            continue
        bytes_installed += path.stat().st_size
        assert not path.name.startswith('._'), 'AppleDouble metadata in host'
        if 'Mach-O' not in run('file', '-b', str(path)):
            continue
        binaries.append(path)
        assert run('lipo', '-archs', str(path)).strip() == 'arm64', f'Unexpected architecture: {path.name}'
        dependencies = run('otool', '-L', str(path))
        for line in dependencies.splitlines()[1:]:
            dependency = line.strip().split(' ')[0]
            assert dependency.startswith(('/System/', '/usr/lib/', '@rpath/', '@loader_path/', '@executable_path/')), f'Nonportable dependency: {dependency}'
        commands = run('otool', '-l', str(path))
        for rpath in re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (\S+) \(offset', commands):
            assert not rpath.startswith('/') or rpath.startswith(('/System/', '/usr/')), f'Build path in {path.name}'
    sparkle_root = bundle / 'Contents/Frameworks/Sparkle.framework'
    sparkle = (sparkle_root / 'Versions/Current').resolve() if (sparkle_root / 'Versions').is_dir() else sparkle_root
    if launcher_required:
        assert sparkle == sparkle_root, 'Shipping Sparkle must use its canonical flat layout'
        assert not any((sparkle_root / name).exists() for name in ('Headers', 'PrivateHeaders', 'Modules')), 'Compiler interfaces in shipping Sparkle'
        assert not any(path.is_symlink() for path in sparkle_root.rglob('*')), 'Shipping Sparkle contains symbolic links'
        assert '/Sparkle.framework/Versions/' not in run('otool', '-L', str(executable)), 'Versioned Sparkle dependency in shipping host'
    expected_binaries = {
        executable,
        sparkle / 'Sparkle', sparkle / 'Autoupdate',
        sparkle / 'Updater.app/Contents/MacOS/Updater',
        sparkle / 'XPCServices/Downloader.xpc/Contents/MacOS/Downloader',
        sparkle / 'XPCServices/Installer.xpc/Contents/MacOS/Installer',
    }
    assert set(binaries) == expected_binaries, 'Unexpected nested host executable'
    symbols = run('nm', '-g', str(executable))
    for feature in ('HerdrStore', 'MusicPlayerEngine', 'MeetingVoice', 'DatabasePage', 'StudioPage', 'QuinjetPage'):
        assert feature not in symbols, f'Feature implementation in host: {feature}'
    assert bytes_installed < 8_000_000, f'Empty host exceeds 8 MB: {bytes_installed}'
    closure = run('otool', '-L', str(executable))
    for feature in ('EdithKit', 'EdithShared', 'MeetingVoice', 'Ghostty', 'EdithStudio', 'NIO', 'GRDB', 'Highlighter'):
        assert feature not in closure, f'Feature dependency in host: {feature}'
    run('codesign', '--verify', '--deep', '--strict', str(bundle))
    if launcher_required:
        signed = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(executable)], capture_output=True, check=True).stdout
        entitlements = plistlib.loads(signed)
        for key in ('com.apple.security.automation.apple-events', 'com.apple.security.device.audio-input', 'com.apple.security.device.camera'):
            assert entitlements.get(key) is True, f'Missing worker entitlement: {key}'
        for key in ('NSAppleEventsUsageDescription', 'NSMicrophoneUsageDescription', 'NSCameraUsageDescription', 'NSLocalNetworkUsageDescription'):
            assert isinstance(plist.get(key), str) and plist[key].strip(), f'Missing worker usage description: {key}'
    catalog = json.loads((bundle / 'Contents/Resources/index.json').read_text())
    assert len(catalog) >= 35
    assert json.loads(run(str(executable), '--version'))['version'] == plist['CFBundleShortVersionString']
    return {'installedBytes': bytes_installed, 'extensionPayloadBytes': 0, 'indexedExtensions': len(catalog), 'signature': 'verified', 'machOBinaries': len(binaries)}
