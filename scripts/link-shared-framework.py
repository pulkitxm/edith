import pathlib
import re
import shutil
import subprocess
import sys

MODULES = (
    'EdithKit',
    'EdithCore',
    'EdithCameraSupport',
    'EdithLidAwakeSupport',
    'EdithShared',
)
SHARED_ID = '@rpath/EdithShared.framework/Versions/A/EdithShared'
REDIRECT = {
    '@rpath/EdithKit.framework/Versions/A/EdithKit':
        '@rpath/EdithShared.framework/Versions/A/EdithKit',
    '@rpath/EdithCore.framework/Versions/A/EdithCore':
        '@rpath/EdithShared.framework/Versions/A/EdithCore',
    '@rpath/EdithCameraSupport.framework/Versions/A/EdithCameraSupport':
        '@rpath/EdithShared.framework/Versions/A/EdithCameraSupport',
    '@rpath/EdithLidAwakeSupport.framework/Versions/A/EdithLidAwakeSupport':
        '@rpath/EdithShared.framework/Versions/A/EdithLidAwakeSupport',
}


def run(command):
    subprocess.run(command, check=True)


def output(command):
    return subprocess.check_output(command, text=True)


def dependencies(binary):
    lines = output(['otool', '-L', str(binary)]).splitlines()[1:]
    return [line.strip().split()[0] for line in lines if line.strip()]


def rpaths(binary):
    text = output(['otool', '-l', str(binary)])
    found = []
    pending = False
    for line in text.splitlines():
        if 'cmd LC_RPATH' in line:
            pending = True
        elif pending and 'path ' in line:
            found.append(line.split('path ', 1)[1].rsplit(' (', 1)[0].strip())
            pending = False
    return found


def retarget(binary):
    for dependency in dependencies(binary):
        if dependency in REDIRECT:
            run(['install_name_tool', '-change', dependency, REDIRECT[dependency], str(binary)])


def drop_build_rpaths(binary):
    for path in rpaths(binary):
        if path.startswith('/') and 'PackageFrameworks' in path:
            run(['install_name_tool', '-delete_rpath', path, str(binary)])


def add_rpath(binary, path):
    if path not in rpaths(binary):
        run(['install_name_tool', '-add_rpath', path, str(binary)])


def link_flags(kit):
    flags = []
    seen = set()
    for dependency in dependencies(kit):
        if dependency.startswith('@rpath/Edith'):
            continue
        match = re.search(r'([^/]+)\.framework/', dependency)
        if match:
            key = ('framework', match.group(1))
            if key not in seen:
                seen.add(key)
                flags.extend(['-framework', match.group(1)])
            continue
        name = pathlib.Path(dependency).name
        if name.startswith('lib') and name.endswith('.dylib'):
            stem = name[3:-6]
            key = ('library', stem)
            if key not in seen:
                seen.add(key)
                flags.append(f'-l{stem}')
    return flags


def object_list(intermediates):
    objects = []
    for name in MODULES:
        listing = intermediates / f'{name}-t.build/Objects-normal/arm64/{name}.LinkFileList'
        objects.extend(listing.read_text().split())
    return objects


def merge(derived, config, app, release):
    products = pathlib.Path(derived) / 'Build/Products' / config
    intermediates = pathlib.Path(derived) / 'Build/Intermediates.noindex/Edith.build' / config
    frameworks = pathlib.Path(app) / 'Contents/Frameworks'
    frameworks.mkdir(parents=True, exist_ok=True)
    shared = frameworks / 'EdithShared.framework'
    source = products / 'PackageFrameworks/EdithShared.framework'
    if not shared.exists():
        shutil.copytree(source, shared, symlinks=True)
    kit = frameworks / 'EdithKit.framework/Versions/A/EdithKit'
    if not kit.exists():
        kit = products / 'PackageFrameworks/EdithKit.framework/Versions/A/EdithKit'
    objects = pathlib.Path(derived) / 'shared-framework-objects.txt'
    objects.write_text('\n'.join(object_list(intermediates)) + '\n')
    developer = pathlib.Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    sdk = output(['xcrun', '--sdk', 'macosx', '--show-sdk-path']).strip()
    command = [
        'clang', '-dynamiclib', '-target', 'arm64-apple-macos14.0', '-isysroot', sdk,
        '-Xlinker', '-install_name', '-Xlinker', SHARED_ID,
        '-filelist', str(objects),
        '-o', str(shared / 'Versions/A/EdithShared'),
        *link_flags(kit),
        '-L/usr/lib/swift',
        f'-L{developer}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx',
    ]
    if release:
        command[1:1] = ['-Xlinker', '-dead_strip']
    run(command)
    objects.unlink()
    version = shared / 'Versions/A'
    developer = pathlib.Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    sdk = output(['xcrun', '--sdk', 'macosx', '--show-sdk-path']).strip()
    for name in REDIRECT:
        alias = name.rsplit('/', 1)[-1]
        run([
            'clang', '-dynamiclib', '-target', 'arm64-apple-macos14.0', '-isysroot', sdk,
            '-Xlinker', '-install_name', '-Xlinker', REDIRECT[name],
            '-Xlinker', '-reexport_library', '-Xlinker', str(version / 'EdithShared'),
            '-Xlinker', '-rpath', '-Xlinker', '@loader_path/../../..',
            '-o', str(version / alias),
            '-L/usr/lib/swift',
            f'-L{developer}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx',
        ])


def main():
    derived, config, app, helper, agent, privileged, camera, camera_binary, release = sys.argv[1:]
    app_path = pathlib.Path(app)
    products = pathlib.Path(derived) / 'Build/Products' / config
    camera_framework = pathlib.Path(camera) / 'Contents/Frameworks/EdithCameraSupport.framework'
    if camera_framework.exists():
        shutil.rmtree(camera_framework)
    shutil.copytree(
        products / 'PackageFrameworks/EdithCameraSupport.framework',
        camera_framework,
        symlinks=True,
    )
    merge(derived, config, app, release == '1')
    for binary in (app_path / 'Contents/MacOS/Edith', pathlib.Path(helper), pathlib.Path(agent)):
        retarget(binary)
        drop_build_rpaths(binary)
    privileged_path = pathlib.Path(privileged)
    retarget(privileged_path)
    add_rpath(privileged_path, '@executable_path/../../Frameworks')
    drop_build_rpaths(privileged_path)
    camera_path = pathlib.Path(camera_binary)
    add_rpath(camera_path, '@executable_path/../Frameworks')
    drop_build_rpaths(camera_path)
    for name in ('EdithKit', 'EdithCore', 'EdithCameraSupport', 'EdithLidAwakeSupport'):
        leftover = app_path / 'Contents/Frameworks' / f'{name}.framework'
        if leftover.exists():
            shutil.rmtree(leftover)


if __name__ == '__main__':
    main()
