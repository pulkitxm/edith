import fcntl
import json
import os
from pathlib import Path
import re
import sys
import tempfile


def read_json(path):
    if path.stat().st_size > 1_048_576:
        raise ValueError('Package plugin approval input exceeds 1 MiB.')
    return json.loads(path.read_text())


def approved_records(repo):
    approved = read_json(repo / 'scripts/trusted-package-plugins.json')
    if not isinstance(approved, list) or not approved:
        raise ValueError('The reviewed package plugin allowlist must be a nonempty array.')
    for record in approved:
        if not isinstance(record, dict) or set(record) != {'fingerprint', 'packageIdentity', 'targetName'}:
            raise ValueError('A reviewed plugin approval record is invalid.')
        if not all(isinstance(value, str) and value for value in record.values()):
            raise ValueError('A reviewed plugin approval field is invalid.')
        if not re.fullmatch('[0-9a-f]{40}', record['fingerprint']):
            raise ValueError('A reviewed plugin fingerprint must be an exact commit revision.')
    for lockfile in [
        'Packages/Edith/Package.resolved',
        'edth.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
    ]:
        pins = read_json(repo / lockfile)['pins']
        for record in approved:
            matches = [pin for pin in pins if pin['identity'] == record['packageIdentity']]
            if len(matches) != 1 or matches[0]['state'].get('revision') != record['fingerprint']:
                raise ValueError('The locked package revision differs from its reviewed plugin approval: '
                                 + record['packageIdentity'])
    return approved


def approve(repo, destination):
    approved = approved_records(repo)
    destination = destination.resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    lock = destination.with_name('.plugins.json.lock')
    with lock.open('a') as ownership:
        fcntl.flock(ownership, fcntl.LOCK_EX | fcntl.LOCK_NB)
        existing = read_json(destination) if destination.exists() else []
        if not isinstance(existing, list) or not all(isinstance(record, dict) for record in existing):
            raise ValueError('Existing Xcode plugin approvals are invalid and were preserved.')
        merged = existing.copy()
        for record in approved:
            if not any(all(prior.get(key) == value for key, value in record.items()) for prior in merged):
                merged.append(record)
        if merged == existing:
            return 0
        descriptor, temporary = tempfile.mkstemp(prefix='.plugins-', dir=destination.parent)
        try:
            with os.fdopen(descriptor, 'w') as output:
                json.dump(merged, output, indent=2)
                output.write('\n')
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, destination)
        finally:
            Path(temporary).unlink(missing_ok=True)
        return len(merged) - len(existing)


if __name__ == '__main__':
    try:
        repo = Path(__file__).resolve().parents[1]
        destination = Path.home() / 'Library/org.swift.swiftpm/security/plugins.json'
        added = approve(repo, destination)
        print(f'Package plugin approvals: {added} reviewed record(s) added.')
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'Package plugin approval refused: {error}', file=sys.stderr)
        sys.exit(1)
