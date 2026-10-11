# Download history fixtures

`python3 scripts/test-download-history.py <fresh-private-fixture-directory>` builds a Foundation-only package from the current music and downloads queue sources. Set `HOME` and `CFFIXED_USER_HOME` to the same fresh synthetic home under the fixture directory's parent, with synthetic `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, and `TMPDIR`. Use `PYTHONDONTWRITEBYTECODE=1` and the Xcode developer directory. The runner uses one build job.

The generated package records every source SHA-256 in `source-receipts.json`. It contains separate owner modules and a synthetic child executable. Both owners use injected fake runners. Boundary adapters fail if local command execution or defaults access is attempted. Native service owners, renderers, download tools, networking, and media playback are excluded.

Fixtures seed the original `Edith/data/downloads.json` location under a private source root. They verify retained files and source associations, worker replacement, development storage isolation, concurrent mutations, corrupt-history protection, shared progress, cross-owner cancellation and retry, late completions, scheduler handoff, restart recovery, and separate-process admission serialization.

`python3 Tests/DownloadHistory/run-foundation-fixtures.py <fresh-private-fixture-directory>` adds the activity storage fixture to the same extracted package. It copies the exact Foundation storage-accounting source and supplies only the missing Cocoa error value as a private boundary. Use the same isolated environment and machine build gate.

Continuation-based fixtures hold three injected flights and assert both original owners project the shared running count and bounded live logs. They hold cancellation drainage separately from completion, accept a retry through the observing owner, and check shutdown or disable/re-enable before successor admission in both owner orders. Concurrent snapshots read atomic sidecar updates, synthetic child owners check final sidecar state, and stale or corrupt activity is recovered without changing history.

Activity persists beside the original history as `Edith/data/downloads.json.activity.json`, with a stable `.lock` sibling. Both owners declare these exact shared leaves. Retention is at most 32 records, 64,000 UTF-8 bytes per record, and 256,000 total log bytes. Serialized JSON also includes record identifiers and escaping overhead. The storage fixture measures actual file bytes, including history, activity, and lock files, once across both owner declarations and the encompassing Usage data directory.

These fixtures execute extracted Foundation code with synthetic files and fake runners. Full extension package builds are compile-only. Original native sheets, product actions, process-group shutdown, and real download behavior remain disposable hosted Mac gates.
