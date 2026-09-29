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
