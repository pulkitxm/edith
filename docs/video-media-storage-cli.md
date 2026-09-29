# Portable media and relinking

These headless routes extend [media inspection and usage](video-media-cli.md).
They return the same version 1 typed envelopes and support `--json` runtime errors.

```sh
ed studio edit media package reel.openscreen --output portable-reel --json
ed studio edit media open moved-reel --dry-run --json
ed studio edit media open moved-reel --overwrite --json
ed studio edit media relink reel.openscreen --reference asset_123 \
  --path originals/renamed.mov --overwrite --json
```

`package` creates a new directory with `project.openscreen` and byte-preserving
original files. It includes cameras, processed audio, original images, cursor
telemetry, wallpaper, and both external annotation-image fields. Color backgrounds
and inline images stay inline. Existing directories are never overwritten. The
parent directory must exist. Publication is atomic; failure removes the staged copy.
The typed `result` contains `directory`, `projectURL`, `copiedFileCount`,
`copiedByteCount`, and `manifest`. The source project is not changed.

`open` verifies every packaged identity and rebases paths to the package's current
directory. It saves the corrected project without launching a window. By default
it requires `--overwrite` to replace the package's project. Use `--output` to create
another project or `--dry-run` to verify without saving. Its `result` is the verified
manifest. A symlink escaping the originals folder is rejected.

`relink` takes a `--reference` from the manifest's `reference.assetID`, a local
`--path`, and an optional `--role`. Roles are `original` (default), `camera`,
`sourceImage`, `processedAudio`, `cursor`, `wallpaper`, `annotationImage`, and
`annotationContent`. Wallpaper references use project IDs; annotation references
use annotation IDs. Cursor associations remain tied to their original movie paths.

The default `--policy requireIdentity` preserves the exact original bytes, including
associated cursor telemetry when relinking a movie. For missing, unindexed media,
provide both `--expected-sha256` and `--expected-bytes`, or use the explicit
`--policy allowReplacement`. Actual content replacement clears obsolete identity,
provenance, format metadata, and derived audio. Identical copies preserve them.
Relink reports `reference`, `previousURL`, `url`, optional `previousIdentity`,
`identity`, and `contentChanged`; it accepts `--output`, `--overwrite`, and `--dry-run`.

All project writes use the shared transaction and revision locks, source protection,
and 32 MiB project limit. Package results are checked against the 4 MiB response limit
before publication. Package copying holds the source publication lock; other writers
can retry after it finishes. These operations are separate from edit-plan transactions.

The MCP names are `edith_studio_edit_media_package`, `edith_studio_edit_media_open`,
and `edith_studio_edit_media_relink`, all write operations. Each uses the standard
MCP `arguments` array with the same CLI flags, a six-hour deadline, and 4 MiB output cap.

## Shared original-source reservations

```sh
ed studio edit media reserve reel.openscreen --ledger shared-ledger.json \
  --reel reel-one --json > receipt.json
ed studio edit media reservations --ledger shared-ledger.json --limit 100 --json
ed studio edit media release --ledger shared-ledger.json --receipt receipt.json --json
```

Use one shared ledger for every reel that must avoid original-source reuse.
`reserve` hashes and verifies used original assets plus their cameras, original
stills, and processed audio. It includes independent audio/music. It reserves whole
sources, so disjoint excerpts still conflict. Byte-identical copies share a key;
explicit alternate-export families share a family key. Repeating a reservation,
even with the same reel ID, fails. The project is not modified.

The successful `reserve` envelope is the release request. Keep its entire stdout in
a file, including `version`, `operation`, `project`, `written`, and `result`. Example:

```json
{
  "version": 1,
  "operation": "reserve",
  "project": "/media/reel.openscreen",
  "written": true,
  "result": {
    "ledger": "/media/shared-ledger.json",
    "receipt": {
      "token": "12345678-1234-4234-8234-123456789012",
      "reelID": "reel-one",
      "keys": ["sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"]
    }
  }
}
```

`written: true` here describes the ledger mutation, not a project save. A reservation
response is validated before committing the ledger, so an oversized response cannot
leave a reservation without its receipt. Receipts are capped at 1 MiB and ledger
files at 32 MiB. Unknown receipt fields, unsupported versions, mismatched ledgers,
modified tokens or keys, partial receipts, and repeated releases are rejected.
The release result has `ledger`, `token`, and `released: true`.

`reservations` accepts `--offset` and `--limit` (1 to 100). Its result has `ledger`,
`total`, `offset`, `limit`, optional `nextOffset`, and `receipts` in UUID-token order.
Counts cover the entire ledger. Listing may initialize the ledger directory and lock
file but does not change reservations. Ledger transactions use canonical parent
directory locks, reject ledger symlinks, and publish complete JSON atomically.

These ledger transactions are independent of edit plans. A later project edit failure
does not undo a reservation; release it explicitly with the saved receipt. Reservation
success does not prove distinct shots within one reel: run the read-only `media usage`
audit with its default visual scope for that acceptance check. Music reuse can be
excluded from that audit, even though the reservation operation covers used audio.
No undeclared re-encode relationship is inferred.

The additional MCP tools are `edith_studio_edit_media_reserve` (write),
`edith_studio_edit_media_reservations` (read), and `edith_studio_edit_media_release`
(write). They have the same CLI flags and JSON envelopes as direct CLI invocation.
