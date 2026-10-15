# `ed studio edit markers`

[Back to `ed studio`](./README.md) · [All CLI commands](../README.md)

Inspect and transactionally edit markers in a local `.openscreen` project. The
default subcommand is `list`. Positions are output frames, independent of later
video edits. Successful commands always emit versioned JSON; `--json` also makes
runtime errors structured JSON on stderr.

Frame-position commands require exactly one of `--fps N/D` or `--project-fps`.
Integer FPS is accepted. Saved rational project FPS takes precedence over native
composition FPS. Empty projects without saved FPS need explicit `--fps`.
Invalid settings fail rather than falling back to 30 fps. Timecodes are non-drop-frame.

## `ed studio edit markers list`

```sh
ed studio edit markers list demo.openscreen --json
```

Returns `version`, `path`, `written: false`, `positionUnit: "output_frames"`, and
`markers`. Entries contain `id`, `frame`, `frameRate: {numerator, denominator}`,
`label`, `kind`, `outputSeconds`, and `nonDropFrameTimecode`.

## `ed studio edit markers add`

```sh
ed studio edit markers add demo.openscreen --frame 60 --fps 60000/1001 --label Cue --json
```

Adds a manual marker. `--frame` is required and nonnegative. `--label` defaults to
`Marker`. Accepts `--dry-run` to validate and return the proposed list without saving.

## `ed studio edit markers update`

```sh
ed studio edit markers update demo.openscreen --id MARKER_ID --label Chorus --json
ed studio edit markers update demo.openscreen --id MARKER_ID --frame 120 --project-fps --json
```

Requires an existing `--id` and at least one change. Label-only updates preserve
saved FPS. `--frame` requires an FPS choice. An FPS-only update preserves output
time, rounded to the nearest frame at the new rate. Accepts `--dry-run`.

## `ed studio edit markers remove`

```sh
ed studio edit markers remove demo.openscreen --id MARKER_ID --json
```

Removes one existing marker by its required `--id`. Accepts `--dry-run`.

## `ed studio edit markers import`

```sh
ed studio edit markers import demo.openscreen --input markers.json --json
```

Requires `--input` pointing to a regular JSON file of at most 32 MiB. The document
contains `version: 1` and `markers`, each with `id`, `frame`, `frameRate`, `label`, and
`kind` (`manual` or `transient`). Import appends by default; `--replace` replaces the
list. Duplicate IDs or invalid entries fail the entire import. Accepts `--dry-run`.

Frame rates have positive numerator and denominator components up to 2147483647,
with a ratio from 1 to 240. Frames range from 0 to 1000000000000. IDs are nonempty
and at most 200 UTF-8 bytes; labels are at most 4096 UTF-8 bytes. The native format
supports 100000 markers, while headless project validation limits arrays to 10000
entries. Mutation reports must fit within 4 MiB before publication.

All marker mutations validate the complete change and media, use the shared project
transaction lock, and publish through a revision-checked atomic save. They update the
named project in place without requiring `--overwrite`. A stale revision fails with
`project_changed`; malformed persisted markers fail rather than becoming an empty list.

## `ed studio edit markers export`

```sh
ed studio edit markers export demo.openscreen --output markers.json --json
```

Requires a `.json` destination. Existing files require `--overwrite`. Project files,
media, sidecars and other project dependencies are protected, including symlink and
hard-link aliases. The file is a version 1 interchange document. The command reports
`version`, `path`, `written`, and `markerCount`.

## `ed studio edit markers snap`

```sh
ed studio edit markers snap demo.openscreen --frame 62 --fps 60000/1001 --threshold-frames 2 --json
```

Read-only nearest-marker lookup. Requires `--frame` and an FPS choice.
`--threshold-frames` defaults to 3 and is inclusive; ties select the earlier frame.
Reports `version`, `requestedOutputFrame`, `outputFrame`, `thresholdFrames`,
`frameRate`, `outputSeconds`, `nonDropFrameTimecode`, and `matched`.

Each leaf has an MCP tool named `edith_studio_edit_markers_` followed by the leaf
name. Tools accept the same CLI options in an `arguments` array. List and snap are
reads; the other routes are writes. MCP deadlines are 120 seconds with a 4 MiB
output limit. Runtime errors use `{version, error: {code, message}}`.

See [audio analysis](./edit-audio.md) to generate a marker document from measured transients.
