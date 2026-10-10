import argparse
import hashlib
import json
import stat
import struct
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from macho_code_identity import executable_identity


def payload_inventory(root, *, identity=executable_identity, verify=None):
    root = Path(root)
    if root.is_symlink() or not root.is_dir() or root.resolve() != root.absolute():
        raise ValueError('Expected a canonical regular role bundle')
    if verify is None:
        verify = lambda path: subprocess.run(['codesign', '--verify', '--deep', '--strict', str(path)], check=True, capture_output=True, timeout=60)
    verify(root)
    resources, code, signatures = {}, {}, {}
    total = 0
    entries = sorted(root.rglob('*'))
    if len(entries) > 100000:
        raise ValueError('Role inventory exceeds its entry bound')
    for path in entries:
        status = path.lstat()
        if stat.S_ISDIR(status.st_mode):
            continue
        if not stat.S_ISREG(status.st_mode) or path.is_symlink():
            raise ValueError('Role inventory contains a nonregular file')
        relative = path.relative_to(root).as_posix()
        if len(relative.encode()) > 4096:
            raise ValueError('Role inventory path exceeds its bound')
        total += status.st_size
        if total > 8 * 1024**3 or status.st_size > 2 * 1024**3:
            raise ValueError('Role inventory exceeds its byte bound')
        data = path.read_bytes()
        record = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'mode': stat.S_IMODE(status.st_mode)}
        if '_CodeSignature' in path.relative_to(root).parts:
            if path.name != 'CodeResources' or path.parent.name != '_CodeSignature':
                raise ValueError('Unexpected signature resource')
            signatures[relative] = record
        elif data[:4] == b'\xcf\xfa\xed\xfe':
            if len(data) < 16:
                raise ValueError('Truncated code header')
            filetype = struct.unpack_from('<I', data, 12)[0]
            if filetype not in (2, 6):
                raise ValueError('Unsupported role code type')
            code[relative] = {**identity(path, filetype=filetype), 'mode': record['mode'], 'filetype': filetype}
        elif data[:4] in (b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'):
            raise ValueError('Unsupported role code architecture')
        else:
            resources[relative] = record
    if not code:
        raise ValueError('Role inventory has no signed native code')
    return {'schema': 1, 'signatureVerified': True, 'regularFiles': len(resources) + len(code) + len(signatures), 'installedBytes': total, 'resources': resources, 'code': code, 'signatures': signatures}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('role_bundle')
    arguments = parser.parse_args()
    print(json.dumps(payload_inventory(arguments.role_bundle), sort_keys=True))
