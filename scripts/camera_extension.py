import datetime
import glob
import hashlib
import os
import plistlib
import re
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


PROFILE_DIRECTORIES = [
    os.path.expanduser('~/Library/Developer/Xcode/UserData/Provisioning Profiles'),
    os.path.expanduser('~/Library/MobileDevice/Provisioning Profiles'),
]


def check_profile(profile, identifier, team, entitlement=None, now=None, device=None,
                  certificates=None):
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
    devices = profile.get('ProvisionedDevices')
    if device and devices is not None and not profile.get('ProvisionsAllDevices'):
        if device not in devices:
            problems.append('profile does not include this Mac')
    if certificates:
        included = {
            hashlib.sha1(bytes(data)).hexdigest().upper()
            for data in profile.get('DeveloperCertificates', [])}
        if not included & {value.upper() for value in certificates}:
            problems.append('profile does not include the signing certificate')
    return problems


def mac_udid():
    output = subprocess.run(
        ['system_profiler', 'SPHardwareDataType'], capture_output=True, text=True).stdout
    match = re.search(r'Provisioning UDID:\s*(\S+)', output)
    return match.group(1) if match else None


def certificate_hashes(identity):
    if not identity or identity == '-':
        return []
    output = subprocess.run(
        ['security', 'find-certificate', '-a', '-c', identity, '-Z'],
        capture_output=True, text=True).stdout
    return re.findall(r'SHA-1 hash:\s*([0-9A-Fa-f]{40})', output)


def candidates(directories):
    paths = []
    for directory in directories:
        for pattern in ('*.provisionprofile', '*.mobileprovision'):
            paths.extend(sorted(glob.glob(os.path.join(directory, pattern))))
    return paths


def find_profile(identifier, team, entitlement, directories=None, decode=None, now=None,
                 device=None, certificates=None):
    decode = decode or decode_profile
    best = None
    for path in candidates(directories or PROFILE_DIRECTORIES):
        try:
            profile = decode(path)
        except Exception:
            continue
        if check_profile(profile, identifier, team, entitlement, now, device, certificates):
            continue
        exact = profile.get('Entitlements', {}).get(
            'com.apple.application-identifier') == f'{team}.{identifier}'
        expiry = profile.get('ExpirationDate') or datetime.datetime.min
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=datetime.timezone.utc)
        rank = (exact, expiry)
        if best is None or rank > best[0]:
            best = (rank, path)
    return best[1] if best else None


PROJECT = """// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{}};
\tobjectVersion = 56;
\tobjects = {{
\t\tA1000000000000000000000A = {{isa = PBXBuildFile; fileRef = A1000000000000000000001A; }};
\t\tA1000000000000000000000B = {{isa = PBXBuildFile; fileRef = A1000000000000000000001B; }};
\t\tA1000000000000000000001A = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App.swift; sourceTree = "<group>"; }};
\t\tA1000000000000000000001B = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Camera.swift; sourceTree = "<group>"; }};
\t\tA1000000000000000000001C = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = App.entitlements; sourceTree = "<group>"; }};
\t\tA1000000000000000000001D = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Camera.entitlements; sourceTree = "<group>"; }};
\t\tA1000000000000000000001E = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ProfileApp.app; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\tA1000000000000000000001F = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ProfileCamera.app; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\tA1000000000000000000002A = {{isa = PBXGroup; children = (A1000000000000000000001A, A1000000000000000000001B, A1000000000000000000001C, A1000000000000000000001D, A1000000000000000000002B, ); sourceTree = "<group>"; }};
\t\tA1000000000000000000002B = {{isa = PBXGroup; children = (A1000000000000000000001E, A1000000000000000000001F, ); name = Products; sourceTree = "<group>"; }};
\t\tA1000000000000000000003A = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A1000000000000000000000A, ); runOnlyForDeploymentPostprocessing = 0; }};
\t\tA1000000000000000000003B = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A1000000000000000000000B, ); runOnlyForDeploymentPostprocessing = 0; }};
\t\tA1000000000000000000004A = {{isa = PBXNativeTarget; buildConfigurationList = A1000000000000000000006A; buildPhases = (A1000000000000000000003A, ); buildRules = (); dependencies = (); name = ProfileApp; productName = ProfileApp; productReference = A1000000000000000000001E; productType = "com.apple.product-type.application"; }};
\t\tA1000000000000000000004B = {{isa = PBXNativeTarget; buildConfigurationList = A1000000000000000000006B; buildPhases = (A1000000000000000000003B, ); buildRules = (); dependencies = (); name = ProfileCamera; productName = ProfileCamera; productReference = A1000000000000000000001F; productType = "com.apple.product-type.application"; }};
\t\tA1000000000000000000005A = {{isa = PBXProject; attributes = {{ TargetAttributes = {{ A1000000000000000000004A = {{ DevelopmentTeam = {team}; ProvisioningStyle = Automatic; }}; A1000000000000000000004B = {{ DevelopmentTeam = {team}; ProvisioningStyle = Automatic; }}; }}; }}; buildConfigurationList = A1000000000000000000006C; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = A1000000000000000000002A; productRefGroup = A1000000000000000000002B; projectDirPath = ""; projectRoot = ""; targets = (A1000000000000000000004A, A1000000000000000000004B, ); }};
\t\tA1000000000000000000007A = {{isa = XCBuildConfiguration; buildSettings = {{ CODE_SIGN_ENTITLEMENTS = App.entitlements; CODE_SIGN_IDENTITY = "Apple Development"; CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = {team}; GENERATE_INFOPLIST_FILE = YES; MACOSX_DEPLOYMENT_TARGET = 14.0; PRODUCT_BUNDLE_IDENTIFIER = {application}; PRODUCT_NAME = ProfileApp; SDKROOT = macosx; SWIFT_VERSION = 5.0; }}; name = Debug; }};
\t\tA1000000000000000000007B = {{isa = XCBuildConfiguration; buildSettings = {{ CODE_SIGN_ENTITLEMENTS = Camera.entitlements; CODE_SIGN_IDENTITY = "Apple Development"; CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = {team}; GENERATE_INFOPLIST_FILE = YES; MACOSX_DEPLOYMENT_TARGET = 14.0; PRODUCT_BUNDLE_IDENTIFIER = {camera}; PRODUCT_NAME = ProfileCamera; SDKROOT = macosx; SWIFT_VERSION = 5.0; }}; name = Debug; }};
\t\tA1000000000000000000007C = {{isa = XCBuildConfiguration; buildSettings = {{ SDKROOT = macosx; }}; name = Debug; }};
\t\tA1000000000000000000006A = {{isa = XCConfigurationList; buildConfigurations = (A1000000000000000000007A, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; }};
\t\tA1000000000000000000006B = {{isa = XCConfigurationList; buildConfigurations = (A1000000000000000000007B, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; }};
\t\tA1000000000000000000006C = {{isa = XCConfigurationList; buildConfigurations = (A1000000000000000000007C, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; }};
\t}};
\trootObject = A1000000000000000000005A;
}}
"""


def write_project(directory, application, team):
    project = os.path.join(directory, 'EdithProfiles.xcodeproj')
    os.makedirs(project, exist_ok=True)
    camera = application + SUFFIX
    with open(os.path.join(project, 'project.pbxproj'), 'w') as handle:
        handle.write(PROJECT.format(team=team, application=application, camera=camera))
    for name in ('App.swift', 'Camera.swift'):
        with open(os.path.join(directory, name), 'w') as handle:
            handle.write('@main\nenum ProfileMain {\n    static func main() {}\n}\n')
    app = app_entitlements(application, team)
    write(os.path.join(directory, 'App.entitlements'), {INSTALL_ENTITLEMENT: app[INSTALL_ENTITLEMENT]})
    write(os.path.join(directory, 'Camera.entitlements'), extension_entitlements(application, team))
    return project


def write(path, value):
    with open(path, 'wb') as handle:
        plistlib.dump(value, handle)


def main(arguments):
    if not arguments:
        raise SystemExit('usage: camera_extension.py info|entitlements|app-entitlements|profile|find|project ...')
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
        path, identifier, team, entitlement = rest[:4]
        identity = rest[4] if len(rest) > 4 else ''
        problems = check_profile(
            decode_profile(path), identifier, team, entitlement or None, device=mac_udid(),
            certificates=certificate_hashes(identity))
        if problems:
            raise SystemExit(f'{path}: ' + '; '.join(problems))
        print(f'{path} authorizes {team}.{identifier}')
    elif command == 'find':
        identifier, team, entitlement = rest[:3]
        identity = rest[3] if len(rest) > 3 else ''
        found = find_profile(
            identifier, team, entitlement or None, device=mac_udid(),
            certificates=certificate_hashes(identity))
        if found:
            print(found)
    elif command == 'project':
        directory, application, team = rest
        print(write_project(directory, application, team))
    else:
        raise SystemExit(f'unknown command {command}')


if __name__ == '__main__':
    main(sys.argv[1:])
