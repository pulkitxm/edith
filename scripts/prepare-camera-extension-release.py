import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid



def execute(*arguments):
    result = subprocess.run(arguments, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f'{arguments[0]} failed during Camera release preparation')
    return result.stdout + result.stderr


def prepare(environment, run=execute):
    identity = environment.get('EXTENSION_SIGN_IDENTITY', '')
    if not identity.startswith(('Developer ID Application:', 'Apple Development:')):
        raise ValueError('Camera release requires a valid MACOS_CERT_P12 signing identity, never ad hoc signing')
    output = Path(environment.get('GITHUB_ENV', ''))
    if not environment.get('GITHUB_ENV') or not output.is_file():
        raise ValueError('GITHUB_ENV must name an existing environment file')
    folder = Path(tempfile.mkdtemp(prefix='camera-release-', dir=environment.get('RUNNER_TEMP')))
    try:
        host = folder / 'Edith.app'
        run('python3', 'scripts/package-shipping-host.py',
            'local/minimal-host/Edith.app', str(host), '--identity', identity, '--release')
        details = run('codesign', '-dvv', str(host)).decode()
        team_match = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', details, re.MULTILINE)
        if not team_match or 'Identifier=com.pulkit.edith\n' not in details:
            raise ValueError('Frozen Camera host must have production identifier com.pulkit.edith and a signing team')
        team = team_match.group(1)
        run('codesign', '--verify', '--deep', '--strict', str(host))
        values = {'EXTENSION_CONTAINING_HOST_APP': str(host)}
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
            print('Prepared signed production Camera microphone host for OBS output')
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error)) from None
