import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


INPUTS = module('production_sparkle_static', Path(__file__).with_name('production-static-inputs.py'))
EXECUTABLES = {
    'sparkleAutoupdate': 'Autoupdate',
    'sparkleUpdater': 'Updater.app/Contents/MacOS/Updater',
    'sparkleDownloader': 'XPCServices/Downloader.xpc/Contents/MacOS/Downloader',
    'sparkleInstaller': 'XPCServices/Installer.xpc/Contents/MacOS/Installer',
}
PREFIX = 'Contents/Frameworks/Sparkle.framework/'


def roles(bundle, expected):
    INPUTS.COHORT.require(bundle.is_absolute() and bundle.resolve(strict=True) == bundle and bundle.is_dir() and not bundle.is_symlink(), 'Noncanonical Sparkle host bundle')
    executable = bundle / 'Contents/MacOS/Edith'
    INPUTS.COHORT.require(hashlib.sha256(INPUTS.bounded_owned_bytes(executable, 16 * 1024**2)).hexdigest() == expected['hostExecutableSHA256'], 'Sparkle host executable differs')
    INPUTS.signing(bundle, expected['teamIdentifier'], expected['designatedRequirement'])
    pins = {}
    result = []
    for role, relative in EXECUTABLES.items():
        path = bundle / PREFIX / relative
        before = INPUTS.bounded_owned_bytes(path, 16 * 1024**2)
        signed = INPUTS.signing(path, expected['teamIdentifier'])
        INPUTS.COHORT.require(INPUTS.bounded_owned_bytes(path, 16 * 1024**2) == before, 'Sparkle executable changed during verification')
        pins[path] = before
        result.append({'role': role, 'executable': '/Applications/Edith.app/' + PREFIX + relative, **signed})
    for path, value in pins.items():
        INPUTS.COHORT.require(INPUTS.bounded_owned_bytes(path, 16 * 1024**2) == value, 'Sparkle input changed during verification')
    INPUTS.COHORT.require(hashlib.sha256(INPUTS.bounded_owned_bytes(executable, 16 * 1024**2)).hexdigest() == expected['hostExecutableSHA256'], 'Sparkle host changed during verification')
    return result


def verify(context):
    INPUTS.COHORT.exact(context, ['request', 'generation', 'directory', 'releaseChannel'])
    request = INPUTS.COHORT.request(json.dumps(context['request']))
    generation = context['generation']
    INPUTS.COHORT.require(generation in ['previous', 'current'], 'Wrong Sparkle cohort generation')
    expected = request['hosts'][generation]
    INPUTS.COHORT.exact(context['releaseChannel'], ['id', 'tag_name', 'target_commitish', 'draft', 'prerelease'])
    INPUTS.release_tag(INPUTS.ROOT, expected, generation, context['releaseChannel'])
    directory = Path(context['directory'])
    INPUTS.COHORT.require(directory.is_absolute() and directory.resolve(strict=True) == directory, 'Noncanonical Sparkle inputs')
    archive = directory / 'Edith.dmg'
    archive_identity = {'bytes': expected['dmgBytes'], 'sha256': expected['dmgSHA256']}
    INPUTS.COHORT.require(INPUTS.STATIC.file_hash(archive) == archive_identity, 'Sparkle DMG differs')
    mount = directory / 'sparkle-mounted'
    mount.mkdir(mode=0o700)
    attached = False
    try:
        INPUTS.command(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', str(mount), str(archive)], 120)
        attached = True
        result = roles(mount / 'Edith.app', expected)
        INPUTS.COHORT.require(INPUTS.STATIC.file_hash(archive) == archive_identity, 'Sparkle DMG changed')
        return result
    finally:
        if attached:
            INPUTS.command(['hdiutil', 'detach', str(mount)], 120)


def main():
    INPUTS.COHORT.require(len(sys.argv) == 2, 'Fixed Sparkle input request required')
    context = INPUTS.STATIC.document(sys.argv[1])
    INPUTS.COHORT.hosted(os.environ, context['request']['source'])
    print(json.dumps(verify(context)))


if __name__ == '__main__':
    main()
