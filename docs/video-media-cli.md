# Original media CLI

`ed studio edit media` runs headlessly against local files. Each command prints a
version 1 typed JSON envelope. `--json` also makes runtime errors JSON on stderr.
No application window, permission dialog, or installed skill is needed.
MCP media calls allow up to six hours for streaming large original collections.

## Inspect and compare

```sh
ed studio edit media identity original.mov --json
ed studio edit media probe original.mov --json
ed studio edit media duplicates original.mov renamed-copy.mov --json
ed studio edit media chronology morning.jpg evening.mov --json
```

`identity` streams SHA-256 and byte count. `probe` adds actual video codecs,
encoded/display dimensions, transforms, nominal frame rates, audio sample rates,
channel counts, image information, and capture metadata. `duplicates` accepts
2 to 1000 paths and returns groups of byte-identical files. `chronology` accepts
1 to 1000 paths and returns inspected media in capture order. None modifies files.

```json
{
  "version": 1,
  "operation": "identity",
  "written": false,
  "result": {
    "url": "file:///media/original.mov",
    "identity": {
      "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      "byteCount": 3
    }
  }
}
```

Capture dates retain `source`, `rawValues`, `utc`, `timezone`, `offsetMinutes`,
and `isOriginalMetadata`. `timezone` is `explicitOffset`, `unknown`, `invalid`, or
`conflicting`. Unavailable optional fields are omitted. Original EXIF and declared
QuickTime original dates take precedence over creation/export metadata. EXIF
subseconds are retained. Filesystem modification time is never used. Known UTC
instants sort first, with content hash and URL tie-breakers; unknown dates sort last.
Byte identity does not detect re-encoded copies automatically.

## Record identities and explicit provenance

```sh
ed studio edit media index reel.openscreen --probe --dry-run --json
ed studio edit media index reel.openscreen --output indexed.openscreen --json
ed studio edit media provenance indexed.openscreen --asset asset_123 \
  --family recording_456 --declaration "Alternate export of recording 456" \
  --overwrite --json
```

`index` records all media references, including original media, processed audio,
camera sources, original stills, cursor telemetry, wallpapers, and external
annotation images. `--probe` records inspected formats and capture metadata too.
`provenance` records a caller-declared source family on an original asset. Asset and
family IDs are limited to 1000 characters, declarations to 4000. Existing identity
or family conflicts are rejected, never silently replaced.

Both commands accept `--output`, `--overwrite`, and `--dry-run`. Replacing the input
requires `--overwrite`. Dry runs validate without publishing. Writes use the shared
project transaction/revision locks, protect all source dependencies, and enforce the
32 MiB project limit. Reports are limited to 4 MiB. The returned `result` is a typed
media manifest; `project` identifies the destination and `written` says whether it
was published. Unknown project settings are retained. Cloning retains asset identity
and provenance while rebinding project-owned wallpaper references to the clone ID.

Runtime errors have `version: 1` and an `error` object containing `code` and `message`.
Codes include `invalid_value`, `invalid_media`, `identity_mismatch`,
`provenance_conflict`, `media_changed`, `project_changed`, and `output_exists`.

## Read-only shot acceptance audit

```sh
ed studio edit media usage --project first.openscreen --project second.openscreen --json
ed studio edit media usage --project first.openscreen --scope all --offset 100 --limit 100 --json
```

`usage` hashes native original files with the streaming identity API and lists every
clip occurrence, including repeated use of the same asset in one cut. Each row has
`index`, `project`, `projectID`, `clipID`, `assetID`, `role`, `sourceIn`, `sourceOut`,
`source.identity`, optional `source.provenance`, and `originalGroup`. Source ranges
are seconds in the asset's own coordinate system. Role is `visual`, `timelineAudio`,
or `independentAudio`. The default `visual` scope excludes independent audio/music;
`all` includes them, even muted tracks. Looping audio has no single `sourceOut`.

The report includes `occurrenceCount`, `uniqueClipCount`, `uniqueByteIdentityCount`,
`uniqueOriginalCount`, and `conflictCount`. Unique clip counts use project path plus
clip ID, excluding independent audio track rows. Unique originals combine exact
byte identities and explicitly declared source families transitively. No filename
heuristics or perceptual matching are used. Counts cover all inputs, not just the page.

Conflicts summarize each reused original group with `withinProject`, `crossProject`,
`exactBytesRepeated`, `declaredFamilyRepeated`, and `wholeOriginalReuse` flags.
Disjoint ranges still violate whole-original uniqueness. Exact-source range overlap
is reported separately as `overlappingExactSourceRanges`. Alternate exports do not
have a proven common timebase, so `rangeRelationship` is
`unknownAcrossExportsOrLoops`, `overlapping`, or `disjoint`. Conflicting family
declarations on identical bytes are surfaced explicitly.

`assessment` is `knownReuseDetected` or `noKnownReuse`. The report always states
`familyRelationshipStatus: "undeclaredReencodesNotRuledOut"`: different hashes do
not prove different recordings. A 45-shot acceptance check should require 45 visual
clip occurrences, 45 unique originals, no conflicts, and separately established
source-family provenance. A successful ledger reservation alone is insufficient.

Inputs are bounded to 100 distinct project paths and 10000 total occurrences.
`--limit` is 1 to 100, default 100. `--offset` pages both ordered collections,
`occurrences` and `conflicts`, with `nextOffset` omitted at the end. Projects sort by
canonical path, clips by timeline position then ID, audio tracks by position then ID,
and original groups by first occurrence. Keep inputs unchanged between pages. Each
project's revision is checked after auditing. Existing indexed identities must match
the files. No project, manifest, or ledger is written.

## MCP and command discovery

All seven routes are registered in the operation catalog, help, and command tree as
`edith_studio_edit_media_identity`, `edith_studio_edit_media_probe`,
`edith_studio_edit_media_duplicates`, `edith_studio_edit_media_chronology`,
`edith_studio_edit_media_index`, `edith_studio_edit_media_provenance`, and
`edith_studio_edit_media_usage`. Inspection and usage are read operations;
indexing and provenance are write operations.
They are independent of edit-plan operations and return data, not follow-up JSON
instructions to execute.
