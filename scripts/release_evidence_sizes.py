import json
from pathlib import Path
import re
import stat
import subprocess

from size_report_filesystem import TreeSnapshot, digest_file


def verify_native_evidence(releases, links, key, current):
    script = '''import {readFile} from 'node:fs/promises';
import {verifiedEvidence,verifiedLineage,verifiedEnvelope,verifiedComposition,closedAssetInventory} from './scripts/hosted-public-release/evidence.mjs';
const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const request = JSON.parse(Buffer.concat(chunks));
const evidence = [], compositions = [], inventories = [];
for (const release of request.releases) {
    const payload = verifiedEvidence(await readFile(release.path),request.key);
    let composition = null;
    if (release.compositionPath) {
        const bytes = await readFile(release.compositionPath);
        const options = release.current ? request.current : {
            source:payload.sourceCommit,runID:payload.runID,attempt:payload.runAttempt,
            records:verifiedEnvelope(bytes,request.key).packages.map(row => row.package),fingerprints:payload.fingerprints
        };
        composition = verifiedComposition(bytes,request.key,options);
    }
    evidence.push(payload);
    compositions.push(composition);
    inventories.push(closedAssetInventory(payload,release.envelope,release.assets,release.composition));
}
const lineages = await Promise.all(request.links.map(async row => verifiedLineage(await readFile(row.path),request.key,row.record)));
process.stdout.write(JSON.stringify({evidence,lineages,compositions,inventories}));'''
    result = subprocess.run(['node', '--input-type=module', '-e', script],
        input=json.dumps({'releases': releases, 'links': links, 'key': key, 'current': current}),
        check=True, capture_output=True, text=True, timeout=60)
    return json.loads(result.stdout)


def measure_native_evidence(directory, links, records, key, current, verify=verify_native_evidence):
    directory, links = Path(directory).absolute(), Path(links).absolute()
    snapshot, link_snapshot = TreeSnapshot(directory), TreeSnapshot(links)
    current_relative = f"{current['source']}/{current['runID']}-{current['attempt']}"
    current_tag = 'extension-evidence/' + current_relative
    if not re.fullmatch(r'[a-f0-9]{40}/[1-9][0-9]*-[1-9][0-9]*', current_relative):
        raise ValueError('Invalid current publication identity')
    current = {**current, 'records': [records[identifier] for identifier in sorted(records)],
               'fingerprints': {identifier: row['sourceFingerprint'] for identifier, row in records.items()}}
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
                r'[a-f0-9]{40}/[1-9][0-9]*-[1-9][0-9]*/[^/]+', name):
            raise ValueError('Unexpected native evidence asset')
        elif path.name == 'native-evidence.json':
            if not 0 < identity[3] <= 1024 ** 2:
                raise ValueError('Native evidence envelope exceeds its bound')
            envelopes.append(path)
        elif path.name == 'publication-composition.json' and not 0 < identity[3] <= 1024 ** 2:
            raise ValueError('Publication composition exceeds its bound')
    if not 1 <= len(envelopes) <= len(records) + 1:
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
    requests = []
    closed_paths = {directory}
    for path in envelopes:
        assets = [{'name': asset.name, 'size': snapshot.entries[asset][3],
                   'digest': 'sha256:' + digest_file(asset)}
                  for asset in snapshot.files if asset.parent == path.parent]
        by_name = {row['name']: {'bytes': row['size'], 'sha256': row['digest'].removeprefix('sha256:')}
                   for row in assets}
        composition = path.parent / 'publication-composition.json'
        is_current = path.parent.relative_to(directory).as_posix() == current_relative
        if is_current and composition not in snapshot.files:
            raise ValueError('Missing current publication composition')
        requests.append({'path': str(path), 'envelope': by_name[path.name], 'assets': assets,
                         'composition': by_name.get(composition.name),
                         'compositionPath': str(composition) if composition in snapshot.files else None,
                         'current': is_current})
        closed_paths.update(asset for asset in snapshot.files if asset.parent == path.parent)
        closed_paths.update([path.parent, path.parent.parent])
    if not any(row['current'] for row in requests):
        raise ValueError('Missing current publication evidence release')
    if set(snapshot.entries) != closed_paths:
        raise ValueError('Unexpected native evidence release inventory')
    ordered_ids = sorted(records)
    verified = verify(requests, [{'path': str(links / (identifier + '.native-evidence.json')),
                                 'record': records[identifier]} for identifier in ordered_ids], key, current)
    if (any(len(verified[field]) != len(envelopes) for field in ['evidence', 'compositions', 'inventories'])
            or len(verified['lineages']) != len(records)):
        raise ValueError('Native evidence verifier inventory differs')
    releases = {}
    current_composition = None
    for request, payload, composition, inventory in zip(requests, verified['evidence'],
            verified['compositions'], verified['inventories']):
        path = Path(request['path'])
        relative = f"{payload['sourceCommit']}/{payload['runID']}-{payload['runAttempt']}"
        tag = 'extension-evidence/' + relative
        if path.parent.relative_to(directory).as_posix() != relative or tag in releases:
            raise ValueError('Native evidence release identity differs')
        rows = [{**asset, 'category': 'signedNativeEvidenceEnvelopes' if asset['name'] == 'native-evidence.json'
                 else 'signedPublicationCompositions' if asset['name'] == 'publication-composition.json'
                 else 'originalNativeEvidenceArchives'} for asset in inventory['assets']]
        releases[tag] = {'tag': tag, 'sourceCommit': payload['sourceCommit'], 'runID': payload['runID'],
            'runAttempt': payload['runAttempt'], 'envelopeSHA256': inventory['envelopeSHA256'],
            'envelopeBytes': inventory['envelopeBytes'], 'originalArchiveBytes': inventory['originalArchiveBytes'],
            'compositionBytes': inventory['compositionBytes'], 'totalEvidenceBytes': inventory['totalEvidenceBytes'],
            'closedAssetInventory': sorted(rows, key=lambda row: row['name']), 'payload': payload,
            'composition': composition}
        if request['current']:
            if payload['fingerprints'] != current['fingerprints']:
                raise ValueError('Native evidence current publication fingerprints differ')
            current_composition = composition
    if current_composition is None:
        raise ValueError('Missing verified current publication composition')
    referenced = {current_tag}
    links_by_id = {row['name'].removesuffix('.native-evidence.json'): row for row in measured_links}
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
        links_by_id[identifier]['lineage'] = lineage
    composition_rows = current_composition['packages']
    if (len(composition_rows) != len(records)
            or {row['package']['id'] for row in composition_rows} != set(records)):
        raise ValueError('Current publication composition package inventory differs')
    for row in composition_rows:
        measured = links_by_id[row['package']['id']]
        lineage = measured['lineage']
        if (row['package'] != lineage['package'] or row['lineageSHA256'] != measured['sha256']
                or row['lineageBytes'] != measured['bytes']
                or any(row[field] != lineage[field] for field in
                       ['sourceCommit', 'runID', 'runAttempt', 'evidenceSHA256', 'evidenceBytes'])):
            raise ValueError('Current publication composition differs from measured signed lineage')
    if referenced != set(releases):
        raise ValueError('Unreferenced native evidence release')
    snapshot.verify()
    link_snapshot.verify()
    return {'currentPublicationTag': current_tag,
            'releases': [releases[tag] for tag in sorted(releases)],
            'links': sorted(measured_links, key=lambda row: row['name']),
            'closedAssetInventory': [{**asset, 'releaseTag': tag} for tag in sorted(releases)
                                     for asset in releases[tag]['closedAssetInventory']],
            'envelopeBytes': sum(row['envelopeBytes'] for row in releases.values()),
            'originalArchiveBytes': sum(row['originalArchiveBytes'] for row in releases.values()),
            'compositionBytes': sum(row['compositionBytes'] for row in releases.values()),
            'totalEvidenceBytes': sum(row['totalEvidenceBytes'] for row in releases.values()),
            'signedLinkBytes': sum(row['bytes'] for row in measured_links)}
