import base64
import datetime
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid

from camera_extension import check_profile


PROFILE_SETTINGS = (
    ('CAMERA_CARRIER_PROVISIONING_PROFILE', 'CAMERA_CARRIER_PROFILE',
     'com.pulkit.edith.cameraCarrier', 'com.apple.developer.system-extension.install'),
    ('CAMERA_EXTENSION_PROVISIONING_PROFILE', 'CAMERA_EXTENSION_PROFILE',
     'com.pulkit.edith.camera', None),
)


def execute(*arguments):
    result = subprocess.run(arguments, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f'{arguments[0]} failed during Camera release preparation')
    return result.stdout + result.stderr


def prepare(environment, run=execute):
    identity = environment.get('EXTENSION_SIGN_IDENTITY', '')
    if not identity.startswith(('Developer ID Application:', 'Apple Development:')):
        raise ValueError('Camera release requires a valid MACOS_CERT_P12 signing identity, never ad hoc signing')
    missing = [secret for secret, path, _, _ in PROFILE_SETTINGS
               if not environment.get(secret) and not environment.get(path)]
    if missing:
        raise ValueError('Configure base64 CMS provisioning profiles in repository secrets: ' + ', '.join(missing))
    output = Path(environment.get('GITHUB_ENV', ''))
    if not environment.get('GITHUB_ENV') or not output.is_file():
        raise ValueError('GITHUB_ENV must name an existing environment file')
    certificate_output = run('security', 'find-certificate', '-a', '-c', identity, '-Z').decode()
    certificates = re.findall(r'SHA-1 hash:\s*([0-9A-Fa-f]{40})', certificate_output)
    if not certificates:
        raise ValueError('MACOS_CERT_P12 signing certificate is unavailable in the current keychain')
    device_output = run('system_profiler', 'SPHardwareDataType').decode()
    device_match = re.search(r'Provisioning UDID:\s*(\S+)', device_output)
    if not device_match:
        raise ValueError('Cannot determine this Mac provisioning UDID')
    folder = Path(tempfile.mkdtemp(prefix='camera-release-', dir=environment.get('RUNNER_TEMP')))
    try:
        profiles = []
        for secret, variable, identifier, entitlement in PROFILE_SETTINGS:
            encoded = environment.get(secret)
            if encoded:
                if len(encoded) > 3_000_000:
                    raise ValueError(f'{secret} exceeds the provisioning profile size limit')
                try:
                    data = base64.b64decode(encoded, validate=True)
                except ValueError:
                    raise ValueError(f'{secret} must contain base64 CMS profile bytes') from None
            else:
                source = Path(environment[variable])
                if not source.is_file() or source.stat().st_size > 2_000_000:
                    raise ValueError(f'{variable} must name a bounded provisioning profile file')
                data = source.read_bytes()
            if not data or len(data) > 2_000_000:
                raise ValueError(f'{secret} must contain a nonempty, bounded provisioning profile')
            path = folder / f'{identifier}.provisionprofile'
            path.write_bytes(data)
            path.chmod(0o600)
            profile = plistlib.loads(run('security', 'cms', '-D', '-i', str(path)))
            profiles.append((variable, path, identifier, entitlement, profile))
        host = folder / 'Edith.app'
        run('python3', 'scripts/package-shipping-host.py',
            'local/minimal-host/Edith.app', str(host), '--identity', identity, '--release')
        details = run('codesign', '-dvv', str(host)).decode()
        team_match = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', details, re.MULTILINE)
        if not team_match or 'Identifier=com.pulkit.edith\n' not in details:
            raise ValueError('Frozen Camera host must have production identifier com.pulkit.edith and a signing team')
        team = team_match.group(1)
        run('codesign', '--verify', '--deep', '--strict', str(host))
        for variable, path, identifier, entitlement, profile in profiles:
            problems = check_profile(profile, identifier, team, entitlement,
                                     device=device_match.group(1), certificates=certificates)
            if not isinstance(profile.get('ExpirationDate'), datetime.datetime):
                problems.append('profile must contain an expiration date')
            if f'{team}.com.pulkit.edith.camera' not in profile.get('Entitlements', {}).get('com.apple.security.application-groups', []):
                problems.append('profile must authorize the shared Camera application group')
            if problems:
                raise ValueError(f'{variable}: ' + '; '.join(problems))
        values = {'EXTENSION_CONTAINING_HOST_APP': str(host), 'CAMERA_SIGN_TEAM': team}
        values.update({variable: str(path) for variable, path, _, _, _ in profiles})
        if any('\n' in value or '\r' in value for value in values.values()):
            raise ValueError('Camera release paths cannot contain line breaks')
        with output.open('a') as handle:
            handle.write(''.join(f'{key}={value}\n' for key, value in values.items()))
        return values
    except Exception:
        shutil.rmtree(folder)
        raise


def prepare_development(environment, run=execute):
    output = Path(environment['GITHUB_ENV'])
    folder = Path(tempfile.mkdtemp(prefix='camera-release-', dir=environment.get('RUNNER_TEMP')))
    try:
        host = folder / 'Edith.app'
        shutil.copytree('local/minimal-host/Edith.app', host, symlinks=True)
        info_path = host / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['CFBundleIdentifier'] = f'com.pulkit.edith.tests.release-{uuid.uuid4()}'
        info_path.write_bytes(plistlib.dumps(info))
        run('codesign', '--force', '--sign', '-', str(host))
        run('codesign', '--verify', '--deep', '--strict', str(host))
        with output.open('a') as handle:
            handle.write(f'EXTENSION_CONTAINING_HOST_APP={host}\n')
        return {'EXTENSION_CONTAINING_HOST_APP': str(host)}
    except Exception:
        shutil.rmtree(folder)
        raise


if __name__ == '__main__':
    try:
        if os.environ.get('DEVELOPMENT') == 'true':
            prepare_development(os.environ)
            print('Prepared synthetic Camera host for development checks')
        else:
            prepare(os.environ)
            print('Prepared signed production Camera host and matching carrier/provider profiles')
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error)) from None
