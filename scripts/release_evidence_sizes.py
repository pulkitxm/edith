import json
from pathlib import Path
import re
import stat
import subprocess

from size_report_filesystem import TreeSnapshot, digest_file


def verify_native_evidence(envelopes, links, key):
    script = '''import {readFile} from 'node:fs/promises';
import {verifiedEvidence,verifiedLineage} from './scripts/hosted-public-release/evidence.mjs';
const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const request = JSON.parse(Buffer.concat(chunks));
const evidence = await Promise.all(request.envelopes.map(async path => verifiedEvidence(await readFile(path),request.key)));
const lineages = await Promise.all(request.links.map(async row => verifiedLineage(await readFile(row.path),request.key,row.record)));
process.stdout.write(JSON.stringify({evidence,lineages}));'''
    result = subprocess.run(['node', '--input-type=module', '-e', script],
        input=json.dumps({'envelopes': [str(path) for path in envelopes], 'links': links, 'key': key}),
        check=True, capture_output=True, text=True, timeout=60)
    return json.loads(result.stdout)


def measure_native_evidence(directory, links, records, key, verify=verify_native_evidence):
    directory, links = Path(directory).absolute(), Path(links).absolute()
    snapshot, link_snapshot = TreeSnapshot(directory), TreeSnapshot(links)
    envelopes = []
    for path, identity in snapshot.entries.items():
        name = path.relative_to(directory).as_posix()
        if path == directory:
            if not stat.S_ISDIR(identity[2]):
                raise ValueError('Native evidence root must be a directory')
            continue
        if stat.S_ISDIR(identity[2]):
            if not re.fullmatch(r'[a-f0-9]{40}(?:/[1-9][0-9]*-[1-9][0-9]*)?', name):
                raise ValueError('Unexpected native evidence directory')
        elif not stat.S_ISREG(identity[2]) or not re.fullmatch(
                r'[a-f0-9]{40}/[1-9][0-9]*-[1-9][0-9]*/(?:native-evidence\.json|[A-Za-z0-9_-]+-[1-9][0-9]*\.zip)', name):
            raise ValueError('Unexpected native evidence asset')
        elif path.name == 'native-evidence.json':
            if not 0 < identity[3] <= 1024 ** 2:
                raise ValueError('Native evidence envelope exceeds its bound')
            envelopes.append(path)
    if not 1 <= len(envelopes) <= len(records):
        raise ValueError('Missing or excess native evidence releases')
    expected_links = {identifier + '.native-evidence.json' for identifier in records}
    measured_links = []
    for path, identity in link_snapshot.entries.items():
        if path == links:
            if not stat.S_ISDIR(identity[2]):
                raise ValueError('Native evidence links root must be a directory')
            continue
        if (path.parent != links or path.name not in expected_links or not stat.S_ISREG(identity[2])
                or not 0 < identity[3] <= 16 * 1024):
            raise ValueError('Unexpected native evidence link inventory')
        measured_links.append({'name': path.name, 'category': 'signedNativeEvidenceLinks',
                               'bytes': identity[3], 'sha256': digest_file(path)})
    if {row['name'] for row in measured_links} != expected_links:
        raise ValueError('Missing native evidence link')
    ordered_ids = sorted(records)
    verified = verify(envelopes, [{'path': str(links / (identifier + '.native-evidence.json')),
                                  'record': records[identifier]} for identifier in ordered_ids], key)
    if len(verified['evidence']) != len(envelopes) or len(verified['lineages']) != len(records):
        raise ValueError('Native evidence verifier inventory differs')
    releases = {}
    closed_paths = {directory}
    for path, payload in zip(envelopes, verified['evidence']):
        relative = f"{payload['sourceCommit']}/{payload['runID']}-{payload['runAttempt']}"
        tag = 'extension-evidence/' + relative
        if path.parent.relative_to(directory).as_posix() != relative or tag in releases:
            raise ValueError('Native evidence release identity differs')
        rows = [{'name': 'native-evidence.json', 'category': 'signedNativeEvidenceEnvelopes',
                 'bytes': snapshot.entries[path][3], 'sha256': digest_file(path)}]
        for artifact in payload['artifacts']:
            archive = path.parent / artifact['assetName']
            if archive not in snapshot.files:
                raise ValueError('Missing original native evidence archive')
            size, digest = snapshot.entries[archive][3], digest_file(archive)
            if size != artifact['artifactBytes'] or digest != artifact['artifactSHA256']:
                raise ValueError('Original native evidence archive bytes or hash differs')
            rows.append({'name': archive.name, 'category': 'originalNativeEvidenceArchives',
                         'bytes': size, 'sha256': digest})
            closed_paths.add(archive)
        closed_paths.update([path, path.parent, path.parent.parent])
        archive_bytes = sum(row['bytes'] for row in rows[1:])
        releases[tag] = {'tag': tag, 'sourceCommit': payload['sourceCommit'], 'runID': payload['runID'],
            'runAttempt': payload['runAttempt'], 'envelopeSHA256': rows[0]['sha256'],
            'envelopeBytes': rows[0]['bytes'], 'originalArchiveBytes': archive_bytes,
            'totalEvidenceBytes': rows[0]['bytes'] + archive_bytes,
            'closedAssetInventory': sorted(rows, key=lambda row: row['name']), 'payload': payload}
    if set(snapshot.entries) != closed_paths:
        raise ValueError('Unexpected original native evidence archive inventory')
    referenced = set()
    for identifier, lineage in zip(ordered_ids, verified['lineages']):
        release = releases.get(lineage['evidenceTag'])
        if (not release or lineage['package'] != records[identifier]
                or lineage['sourceCommit'] != release['sourceCommit'] or lineage['runID'] != release['runID']
                or lineage['runAttempt'] != release['runAttempt']
                or lineage['evidenceSHA256'] != release['envelopeSHA256']
                or lineage['evidenceBytes'] != release['envelopeBytes']
                or identifier not in release['payload']['plannedIDs']
                or records[identifier]['sourceFingerprint'] != release['payload']['fingerprints'][identifier]):
            raise ValueError('Signed native evidence link differs from original lineage')
        referenced.add(lineage['evidenceTag'])
        row = next(row for row in measured_links if row['name'] == identifier + '.native-evidence.json')
        row['lineage'] = lineage
    if referenced != set(releases):
        raise ValueError('Unreferenced native evidence release')
    snapshot.verify()
    link_snapshot.verify()
    return {'releases': [releases[tag] for tag in sorted(releases)],
            'links': sorted(measured_links, key=lambda row: row['name']),
            'closedAssetInventory': [{**asset, 'releaseTag': tag} for tag in sorted(releases)
                                     for asset in releases[tag]['closedAssetInventory']],
            'envelopeBytes': sum(row['envelopeBytes'] for row in releases.values()),
            'originalArchiveBytes': sum(row['originalArchiveBytes'] for row in releases.values()),
            'totalEvidenceBytes': sum(row['totalEvidenceBytes'] for row in releases.values()),
            'signedLinkBytes': sum(row['bytes'] for row in measured_links)}
