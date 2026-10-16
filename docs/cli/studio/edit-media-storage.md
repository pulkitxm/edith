# Media packages and reservations

[Back to `ed studio`](./README.md) · [All CLI commands](../README.md)

These headless `ed studio edit media` commands use the same typed version 1
envelopes as [media inspection](./edit-media.md). Results always print JSON;
`--json` also makes runtime errors JSON on stderr. MCP tools have the prefix
`edith_studio_edit_media_`, take the same flags through `arguments`, and allow
six hours with a 4 MiB output cap. Package, open, relink, reserve, and release are
write operations; reservations is read-only apart from initializing its lock file.

## `ed studio edit media package`

```sh
ed studio edit media package reel.openscreen --output portable-reel --json
```

Requires one source project and `--output DIRECTORY`. Copies original media,
cameras, processed audio, original stills, cursor telemetry, wallpaper, and both
external annotation-image fields without re-encoding. Inline images and colors
stay inline. The directory contains `project.openscreen` and `originals`.

The parent directory must exist, and an existing destination is never replaced.
Publication is atomic and failed staging is removed. The source project is not
changed. The result contains `directory`, `projectURL`, `copiedFileCount`,
`copiedByteCount`, and `manifest`. Project and response sizes are validated before
publication. The source publication lock is held while copying.

## `ed studio edit media open`

```sh
ed studio edit media open moved-reel --dry-run --json
ed studio edit media open moved-reel --overwrite --json
```

Takes a package directory, verifies all packaged identities, and rebases references
to its current location. It saves a corrected project without launching a window.
The default destination is the package's `project.openscreen`, requiring
`--overwrite`. `--output PATH` creates another `.openscreen` file; `--dry-run`
verifies without writing. Symlinks escaping the originals directory fail.
The result is the verified manifest with `version` and `entries`.

## `ed studio edit media relink`

```sh
ed studio edit media relink reel.openscreen --reference asset_123 \
  --path renamed.mov --overwrite --json
```

Requires a project, `--reference ID`, and `--path FILE`. Reference IDs come from
`reference.assetID` in the media index. `--role` defaults to `original`; other roles
are `camera`, `sourceImage`, `processedAudio`, `cursor`, `wallpaper`,
`annotationImage`, and `annotationContent`. Wallpaper uses a project ID;
annotations use annotation IDs. Cursor paths remain tied to their original movie.

`--policy requireIdentity` is the default and verifies exact bytes, including
associated cursor telemetry for movie relinks. Missing unindexed originals need
both `--expected-sha256 HASH` and `--expected-bytes COUNT`, or the explicit
`--policy allowReplacement`. Changed content clears obsolete provenance, format
metadata, and derived audio; identical copies preserve them.

Accepts `--output PATH`, `--overwrite`, and `--dry-run` with the same defaults as
open. Project writes use shared revision locks, source protection, and the 32 MiB
serialized project limit. The result contains `reference`, `previousURL`, `url`,
optional `previousIdentity`, `identity`, and `contentChanged`.

## `ed studio edit media reserve`

```sh
ed studio edit media reserve reel.openscreen --ledger shared.json \
  --reel reel-one --json > receipt.json
```

Requires a project, shared local `.json` `--ledger`, and `--reel` owner ID of 1 to
1000 characters. Reserves used originals plus cameras, original stills and
processed audio, including independent music. Exact copies and explicitly declared
source families conflict across reels, even for disjoint excerpts. Repeating a
reservation with the same owner also fails. The project is not modified.

The result has `ledger` and `receipt`; the receipt has a UUID `token`, `reelID`, and
sorted `keys` containing `sha256:` and optional `family:` entries. Retain the entire
successful reserve envelope, including `version: 1`, `operation: "reserve"`,
`project`, `written: true`, and `result`, for release. Here `written` describes the
ledger mutation. Receipts are capped at 1 MiB and validated before committing;
ledger reads and writes are capped at 32 MiB.

Use one ledger across all reels. Reservations are independent of edit-plan
transactions. Later project failures do not undo them. Reservation success does not
prove unique shots within one reel: run the [usage audit](./edit-media.md) with its
default visual scope to exclude reused music and inspect every clip occurrence.

## `ed studio edit media reservations`

```sh
ed studio edit media reservations --ledger shared.json --offset 0 --limit 100 --json
```

Requires a local `.json` `--ledger`. Optional `--offset` defaults to 0 and must be
nonnegative. `--limit` defaults to 100 and accepts 1 to 100. The result contains
`ledger`, `total`, `offset`, `limit`, optional `nextOffset`, and `receipts`, ordered
by UUID token. Listing may initialize the ledger directory and lock file but does
not modify reservations. Keep the ledger unchanged between pages.

## `ed studio edit media release`

```sh
ed studio edit media release --ledger shared.json --receipt receipt.json --json
```

Requires the original `.json` `--ledger` and a `--receipt FILE` containing the
complete successful reserve envelope, at most 1 MiB. Unknown fields, unsupported
versions, mismatched ledgers, modified tokens or keys, partial receipts, and repeated
releases fail. The result contains `ledger`, `token`, and `released: true`.
Ledger transactions use canonical parent-directory locks, reject ledger symlinks,
and publish complete JSON atomically. Release never modifies the project.
