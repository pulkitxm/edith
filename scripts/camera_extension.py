import datetime
import plistlib
import subprocess
import sys

PRODUCTION = 'com.pulkit.edith'
SUFFIX = '.camera'
INSTALL_ENTITLEMENT = 'com.apple.developer.system-extension.install'


def slot_of(application):
    prefix = PRODUCTION + '.dev.'
    if application == PRODUCTION:
        return ''
    if application.startswith(prefix):
        return application[len(prefix):]
    return application[len(PRODUCTION) + 1:]


def display_name(application):
    slot = slot_of(application)
    return f'Edith Camera ({slot})' if slot else 'Edith Camera'


def mach_service(identifier, team):
    return f'{team}.{identifier}' if team else identifier


def info(application, version, build, team):
    identifier = application + SUFFIX
    name = display_name(application)
    return {
        'CFBundleDevelopmentRegion': 'en',
        'CFBundleDisplayName': name,
        'CFBundleExecutable': identifier,
        'CFBundleIdentifier': identifier,
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': name,
        'CFBundlePackageType': 'SYSX',
        'CFBundleShortVersionString': version,
        'CFBundleSupportedPlatforms': ['MacOSX'],
        'CFBundleVersion': build,
        'LSMinimumSystemVersion': '14.0',
        'NSSystemExtensionUsageDescription':
            'Edith Camera lets video apps use the camera picture you frame in Edith.',
        'CMIOExtension': {'CMIOExtensionMachServiceName': mach_service(identifier, team)},
    }


def extension_entitlements(application, team):
    value = {'com.apple.security.app-sandbox': True}
    if team:
        value['com.apple.security.application-groups'] = [
            mach_service(application + SUFFIX, team)]
    return value


def app_entitlements(application, team):
    return {
        INSTALL_ENTITLEMENT: True,
        'com.apple.application-identifier': f'{team}.{application}',
        'com.apple.developer.team-identifier': team,
    }


def decode_profile(path):
    decoded = subprocess.run(
        ['security', 'cms', '-D', '-i', path], capture_output=True, check=True)
    return plistlib.loads(decoded.stdout)


def check_profile(profile, identifier, team, entitlement=None, now=None):
    problems = []
    entitlements = profile.get('Entitlements', {})
    expected = f'{team}.{identifier}'
    granted = entitlements.get('com.apple.application-identifier', '')
    if granted != expected and not (
            granted.endswith('.*') and expected.startswith(granted[:-1])):
        problems.append(f'profile is for {granted or "no app"}, not {expected}')
    if team not in profile.get('TeamIdentifier', []):
        problems.append(f'profile belongs to another team than {team}')
    if entitlement and not entitlements.get(entitlement):
        problems.append(f'profile does not grant {entitlement}')
    expiry = profile.get('ExpirationDate')
    current = now or datetime.datetime.now(datetime.timezone.utc)
    if expiry is not None:
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=datetime.timezone.utc)
        if expiry <= current:
            problems.append(f'profile expired on {expiry:%Y-%m-%d}')
    return problems


def write(path, value):
    with open(path, 'wb') as handle:
        plistlib.dump(value, handle)


def main(arguments):
    if not arguments:
        raise SystemExit('usage: camera_extension.py info|entitlements|app-entitlements|profile ...')
    command, rest = arguments[0], arguments[1:]
    if command == 'info':
        destination, application, version, build, team = rest
        write(destination, info(application, version, build, team))
    elif command == 'entitlements':
        destination, application, team = rest
        write(destination, extension_entitlements(application, team))
    elif command == 'app-entitlements':
        destination, application, team = rest
        write(destination, app_entitlements(application, team))
    elif command == 'profile':
        path, identifier, team, entitlement = rest
        problems = check_profile(decode_profile(path), identifier, team, entitlement or None)
        if problems:
            raise SystemExit(f'{path}: ' + '; '.join(problems))
        print(f'{path} authorizes {team}.{identifier}')
    else:
        raise SystemExit(f'unknown command {command}')


if __name__ == '__main__':
    main(sys.argv[1:])
