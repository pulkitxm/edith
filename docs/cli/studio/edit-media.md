# `ed studio edit media`

[Back to `ed studio`](./README.md) · [All CLI commands](../README.md)

Inspect local originals, record verified identities and explicit source families,
and audit every clip occurrence across projects. All operations run headlessly.
Each successful command prints one typed JSON envelope with `version: 1`,
`operation`, `written`, and `result`. Project mutations also include `project`.
`--json` makes runtime errors JSON on stderr with `version`, `error.code`, and
`error.message`. Success exits 0, invalid inputs exit 2, and other failures exit 1.

MCP tool names are `edith_studio_edit_media_<command>`. Pass the same arguments
through the MCP `arguments` array. Calls allow six hours; output is capped at 4 MiB.

## `ed studio edit media identity`

```sh
ed studio edit media identity original.mov --json
```

Streams SHA-256 for one readable local file. The read-only result contains `url`
and `identity`, with lowercase hexadecimal `sha256` and integer `byteCount`.

```json
{"version":1,"operation":"identity","written":false,"result":{"url":"file:///media/original.mov","identity":{"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","byteCount":3}}}
```

## `ed studio edit media probe`

```sh
ed studio edit media probe original.mov --json
```

Returns `url`, `source.identity`, optional `source.provenance`, and `metadata`.
Native metadata includes video codecs, encoded/display dimensions, transform,
nominal frame rate, audio codec/sample rate/channel count, image properties, and
capture-date certainty. Unsupported media fails rather than guessing from its name.

`metadata.captureDate` preserves `source`, `rawValues`, `utc`, `timezone`,
`offsetMinutes`, and `isOriginalMetadata`. Unavailable optional values are omitted.
Timezone is `explicitOffset`, `unknown`, `invalid`, or `conflicting`. Original
metadata takes precedence over creation/export dates. Unknown offsets never become
UTC, and filesystem timestamps never become capture dates.

## `ed studio edit media duplicates`

```sh
ed studio edit media duplicates original.mov renamed-copy.mov --json
```

Accepts 2 to 1000 positional paths. Returns byte-identical groups containing
`identity` and `urls`. It does not infer source families for different encodings.

## `ed studio edit media chronology`

```sh
ed studio edit media chronology morning.jpg evening.mov --json
```

Accepts 1 to 1000 positional paths and returns inspected media in deterministic
capture order. Known UTC instants sort first, using content hash and URL for ties;
unknown capture times sort last. EXIF subseconds are retained. Files are not modified.

## `ed studio edit media index`

```sh
ed studio edit media index reel.openscreen --probe --dry-run --json
ed studio edit media index reel.openscreen --output indexed.openscreen --json
```

Records verified identities for original media, cameras, processed audio, original
stills, cursor telemetry, wallpaper, and both external annotation-image fields.
`--probe` also records native format and capture metadata. The result is a manifest
with `version: 1` and `entries`. Each entry has `reference.assetID`, `reference.role`,
`source.identity`, and optional provenance, metadata, and packaged path.

| Option | Default | Meaning |
| --- | --- | --- |
| `--probe` | off | Include native format and capture metadata. |
| `--output PATH` | input project | Save a separate `.openscreen` file. |
| `--overwrite` | off | Explicitly permit replacement of an existing project. |
| `--dry-run` | off | Validate without writing. |
| `--json` | off | Emit structured runtime errors; results are always JSON. |

Writes use shared project transaction/revision locks, protect source dependencies,
and enforce the 32 MiB serialized project limit. An existing identity mismatch is
rejected. Replacing the input requires `--overwrite`; dry runs do not require it.

## `ed studio edit media provenance`

```sh
ed studio edit media provenance reel.openscreen --asset asset_123 \
  --family recording_456 --declaration "Explicit alternate export" --overwrite --json
```

Declares a source family for an original asset. Required `--asset` and `--family`
values are limited to 1000 characters; required `--declaration` is limited to 4000.
They must be nonempty. Accepts the same `--output`, `--overwrite`, `--dry-run`, and
`--json` options as index, and returns a manifest. Existing family conflicts fail.
Different encodings share identity only through explicit declarations, never names.

## `ed studio edit media usage`

```sh
ed studio edit media usage --project first.openscreen --project second.openscreen --json
ed studio edit media usage --project reel.openscreen --scope all --offset 100 --limit 100 --json
```

Audits every clip occurrence, including repeated use of one asset within a reel.
Required `--project` may be repeated for 1 to 100 distinct paths. `--scope visual`
is the default and excludes independent music/audio; `--scope all` includes it,
even muted tracks. `--offset` defaults to 0 and accepts 0 to 10000. `--limit` defaults
to 100 and accepts 1 to 100. Inputs are capped at 10000 total occurrences.

The result contains `scope`, `projectCount`, `occurrenceCount`, `uniqueClipCount`,
`uniqueByteIdentityCount`, `uniqueOriginalCount`, `conflictCount`, `assessment`,
`familyRelationshipStatus`, `excludedIndependentAudioCount`, `offset`, `limit`,
optional `nextOffset`, and paginated `occurrences` and `conflicts`. Counts cover all
inputs. Unique originals combine exact bytes and declared families transitively.

Occurrences contain `index`, `project`, `projectID`, `clipID`, `assetID`, `role`,
`sourceRole`, `sourceRangeComparable`,
`sourceIn`, optional `sourceOut`, `source.identity`, optional `source.provenance`,
and `originalGroup`. Ranges use source seconds. Roles are `visual`, `timelineAudio`,
or `independentAudio`; looping audio has no single source end. Independent audio
rows are excluded from `uniqueClipCount`.
Non-looping independent audio consumes its exact persisted output duration multiplied
by playback rate, starting at its source offset and capped at the source duration.

Still carriers use `edithSourceImagePath` and its indexed `sourceImage` identity;
other assets use their original URL and `original` identity. Source-image provenance
takes precedence, falling back to the original asset's explicit family declaration.
Still images have `sourceRangeComparable: false`: carrier seconds cannot establish
disjoint photographic originals. Their conflict range relationship is
`notComparableForStillOriginals`, with no inferred temporal overlap.

Conflict groups expose `originalGroup`, `occurrenceCount`, `withinProject`,
`crossProject`, `exactBytesRepeated`, `declaredFamilyRepeated`, `wholeOriginalReuse`,
`overlappingExactSourceRanges`, `rangeRelationship`, and
`conflictingFamilyDeclarations`. Disjoint excerpts still reuse the whole original.
Range relationships are `overlapping`, `disjoint`, or `unknownAcrossExportsOrLoops`;
alternate exports have no proven common timebase.

Assessment is `knownReuseDetected` or `noKnownReuse`. Family relationship status
always states `undeclaredReencodesNotRuledOut`. A 45-shot acceptance check needs 45
visual occurrences, 45 unique originals, no conflicts, and separately established
source-family provenance. A successful reservation alone does not prove this.

Projects sort by canonical path, clips and audio by timeline position then ID, and
groups by first occurrence. Both collections use the same offset and limit; follow
`nextOffset` while keeping inputs unchanged. The audit checks project revisions and
indexed identities but writes no project, media, manifest, or ledger.
