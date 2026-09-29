# `ed studio edit captions`

[Back to the CLI reference](../README.md)

Create and edit native captions on the rendered output clock, without opening a window.
These commands use the same text appearance and renderer as the native caption editor.
Existing edit-plan `text` operations continue to use source-ruler seconds.

```sh
ed studio edit captions add demo.openscreen --text "First beat" --start-frame 12 --end-frame 24 --fps 60 --json
ed studio edit captions list demo.openscreen --json
ed studio edit captions update demo.openscreen annotation_returned_id --text "Next beat" --end-frame 30 --fps 60 --json
ed studio edit captions remove demo.openscreen annotation_returned_id --dry-run --json
ed studio edit captions remove demo.openscreen annotation_returned_id --json
```

Use the actual `captionID` returned by `add`. It remains stable across updates and native edits.
`update` and `remove` fail for unknown IDs; they never silently succeed.

## Frames, markers and clocks

Start is inclusive and end is exclusive. Frames are nonnegative integers, at most
1,000,000,000,000, with a positive rational FPS between 1 and 240. Numerator and
denominator must fit Int32, and frame multiplied by denominator must fit Int64.
FPS accepts `60`, `30000/1001`, or `project`. Add defaults to project FPS; updating
integer frame boundaries requires an explicit `--fps` choice. Updating only text
preserves timing exactly. Native timing edits snap to the stored endpoint rates.

Marker IDs can replace either frame boundary:

```sh
ed studio edit captions add demo.openscreen --text "On the beat" --start-marker marker_first --end-marker marker_next --json
ed studio edit captions update demo.openscreen annotation_returned_id --start-marker marker_later --json
```

Each marker resolves to its exact frame and rational rate when the operation runs.
The result keeps `markerID` as provenance, not a live link. Moving or removing the
marker later does not move the caption. Mixed-rate markers retain their own rates;
they are not rounded to project FPS. A frame and marker cannot both specify one boundary.

The persisted output anchor contains independent `start` and `end` objects with
`frame`, `frameRate: {numerator, denominator}`, and optional `markerID`. Its actual
times remain unchanged by clip speed, skipped ranges, reordering, or project FPS
changes. Rendering compares composition timestamps against the rational interval.
A new FPS samples that same interval on its new output frame grid. Retiming beyond
the end of a shortened edit does not discard the anchor; it is simply outside the render.
Creating or changing timing requires a nonempty interval inside the current composition.

Native caption selection, timeline edges, text/style editing, split, same-clock merge,
subtitle export and undo preserve the output clock. Source-clock captions appear in
`list` too. Text-only updates keep their clock; supplying both output boundaries
explicitly converts one to the output clock.

## Results and safety

Results are always JSON: `version`, `path`, `written`, optional `captionID`, and
`captions`. Each caption includes `id`, `content`, `clock` (`output` or `source_ruler`),
optional `anchor`, and `startSeconds`/`endSeconds` in its stated clock.

Mutations update the input project atomically with the shared transaction lock and
revision check. `--dry-run` validates without writing; its generated add ID is provisional.
Failures leave the project bytes unchanged. Text is limited to 10000 UTF-8 bytes,
adds allow at most 10000 annotations, projects are bounded to 32 MiB and reports to
4 MiB. Unknown CLI options and unknown persisted anchor fields are rejected.
`--json` produces structured runtime errors; syntax errors use the standard parser.

MCP tools are `edith_studio_edit_captions_list`, `edith_studio_edit_captions_add`,
`edith_studio_edit_captions_update`, and `edith_studio_edit_captions_remove`.
Pass CLI arguments through their `arguments` array. List is read-only; other routes
are writes. The public native API is `VideoEditorService.listCaptions` and
`changeCaption(_:in:dryRun:)`, with typed `CaptionChange`, `CaptionBoundary`,
`CaptionRate`, `VideoCaptionFrameRate`, `VideoCaptionPosition` and `VideoCaptionAnchor`.
