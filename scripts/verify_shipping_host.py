import json
from pathlib import Path
import plistlib
import re
import subprocess


def run(*arguments):
    result = subprocess.run(arguments, capture_output=True, text=True, check=True)
    return result.stdout + result.stderr


def inspect_host(bundle, release=False, launcher_required=True):
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
    allowed = {'Info.plist', 'MacOS', 'Frameworks', 'Resources', '_CodeSignature'}
    assert {path.name for path in (bundle / 'Contents').iterdir()} <= allowed, 'Unexpected host payload directory'
    assert {path.name for path in (bundle / 'Contents/MacOS').iterdir()} == ({'Edith', 'ed'} if launcher_required else {'Edith'}), 'Unexpected host executable'
    assert {path.name for path in (bundle / 'Contents/Frameworks').iterdir()} == {'libExtensionMarketplace.dylib', 'Sparkle.framework'}, 'Feature framework in host'
    resources = {'AppIcon.icns', 'index.json', 'ed-launcher'} if launcher_required else {'AppIcon.icns', 'index.json'}
    assert {path.name for path in (bundle / 'Contents/Resources').iterdir()} == resources, 'Feature resources in host'
    if launcher_required:
        launcher = bundle / 'Contents/MacOS/ed'
        assert launcher.is_symlink() and launcher.readlink() == Path('../Resources/ed-launcher')
        assert (bundle / 'Contents/Resources/ed-launcher').read_text().startswith('#!/bin/sh\n')
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
    assert bytes_installed < 5_000_000, f'Empty host exceeds 5 MB: {bytes_installed}'
    closure = run('otool', '-L', str(executable), str(bundle / 'Contents/Frameworks/libExtensionMarketplace.dylib'))
    for feature in ('EdithKit', 'EdithShared', 'MeetingVoice', 'Ghostty', 'EdithStudio', 'NIO', 'GRDB', 'Highlighter'):
        assert feature not in closure, f'Feature dependency in host: {feature}'
    run('codesign', '--verify', '--deep', '--strict', str(bundle))
    catalog = json.loads(run(str(executable), 'extensions', 'catalog', '--json'))
    assert len(catalog) >= 35
    assert run(str(executable), '--version').strip() == plist['CFBundleShortVersionString']
    return {'installedBytes': bytes_installed, 'extensionPayloadBytes': 0, 'indexedExtensions': len(catalog), 'signature': 'verified', 'machOBinaries': len(binaries)}
