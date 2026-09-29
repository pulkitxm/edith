# Headless video editing

`ed studio edit` edits the same `.openscreen` project files and uses the same native
render pipeline as the video editor. It runs locally without opening an editor window.
Original media remains in place. Projects reference absolute source paths.

## Commands

```sh
ed studio edit schema
ed studio edit create demo.openscreen --title "Synthetic demo" --json
ed studio edit apply demo.openscreen --plan edit.json --dry-run --json
ed studio edit apply demo.openscreen --plan edit.json --overwrite --json
ed studio edit show demo.openscreen --json
ed studio edit validate demo.openscreen --json
ed studio edit render demo.openscreen --output demo.mp4 --json
ed studio edit frame demo.openscreen --time 0.25 --output preview.png --json
```

Create the destination directory first. Every write refuses an existing destination
unless `--overwrite` is passed. Apply without `--output` replaces its input and therefore
needs `--overwrite`. Use `--output revised.openscreen` to save a separate project.
Writes publish a complete temporary file atomically. Failed exports preserve the old
output. Source media, associated audio, camera media, image sources and cursor sidecars
cannot be output destinations. Destination symlinks and directories are rejected.
Filesystem wallpapers and image annotations are protected too; inline image data is
not treated as a path.

`--dry-run` executes and validates all operations in memory, including probing added
media, but writes no files. It does not require `--overwrite`. IDs generated during a dry
run are previews; a subsequent apply creates fresh IDs. An invalid operation aborts the
whole plan, and the input project remains byte-for-byte unchanged.

Concurrent CLI applies serialize per source project. Before publication, the CLI checks
that the source bytes still match the revision it read. Native UI saves share a short
publication lock, so a UI save during validation produces a `project_changed` failure
instead of being overwritten. Native saves also compare their loaded revision, so an
older open UI project cannot silently replace a later CLI edit. Contended native saves
return `project_busy` for retry. A private per-user temporary lock directory coordinates
these writers by canonical project path, including read-only sources with separate output.
Lock files remain in place to preserve identity. Dry-run does not create lock files.

## Version 1 plans

Save this as `edit.json`, beside a local video named `synthetic.mov`:

```json
{
  "version": 1,
  "operations": [
    {"addMedia": {"path": "synthetic.mov", "name": "intro"}},
    {"split": {"clipID": "intro", "sourceTime": 0.5, "rightName": "outro"}},
    {"trim": {"clipID": "intro", "start": 0.1, "end": 0.5}},
    {"speed": {"clipID": "intro", "rate": 2}},
    {"sourceAudio": {"clipID": "intro", "gainDb": -6, "muted": false}},
    {"crop": {"clipID": "intro", "x": 0.1, "y": 0.1, "width": 0.8, "height": 0.8}},
    {"reorder": {"clipIDs": ["outro", "intro"]}},
    {"transition": {"clipID": "intro", "kind": "fade", "duration": 0.2}},
    {"text": {"content": "Synthetic demo", "start": 0.1, "end": 0.4}},
    {"canvas": {"aspectRatio": "1:1", "padding": 10, "backgroundColor": "#171b25"}}
  ]
}
```

The input video must be at least one second long for this example. Use the public
schema to construct plans; project JSON itself is not the edit interface. Each operation
is one object with one operation name and its required, typed fields. Unknown fields,
unknown operations and unsupported versions are rejected. Plans are limited to 4 MiB
and 1000 operations. Project files are limited to 32 MiB and 10000 clips or assets.
The 32 MiB limit also applies to the final serialized output, including pretty-print
formatting, during both apply and dry-run.

Operations run in order. `addMedia.name` and `split.rightName` define plan-local aliases
for newly created clips. Later operations can use either an alias or a persisted clip ID
from `show`. Result JSON returns aliases and the final ordered clip IDs. Aliases are not
saved as project IDs. Relative media paths resolve beside the plan file, including when
the project lives elsewhere. Absolute paths and `~` paths are also supported.

| Operation | Fields and semantics |
| --- | --- |
| `addMedia` | `path`, `name`. Probe and append a local file with a native-decodable video track. |
| `split` | `clipID`, `sourceTime`, `rightName`. Source seconds; each side must exceed 0.05 seconds. |
| `trim` | `clipID`, `start`, `end`. Keep this source range, longer than 0.05 seconds. |
| `reorder` | `clipIDs`. Every current clip exactly once, in the desired order. |
| `remove` | `clipID`. Remove the clip and its anchored regions. Source files stay intact. |
| `speed` | `clipID`, `rate`. Replace clip speed, from 0.25 to 5. |
| `sourceAudio` | `clipID`, `gainDb`, `muted`. Gain from -60 to +12 dB. |
| `crop` | `clipID`, `x`, `y`, `width`, `height`. Normalized top-left coordinates; minimum size 0.05; must fit inside the image. |
| `resetCrop` | `clipID`. Restore the full source image. |
| `text` | `content`, `start`, `end`. Add a text annotation using native defaults. |
| `transition` | `clipID`, `kind`, `duration`. Before a non-first clip; `fade`, `flash`, or `none`; 0.2 to 2 seconds. |
| `addAudio` | `path`, `start`, `offset`. Add native clip-anchored audio, clipped at the timeline end. Offset is source seconds. |
| `audioOptions` | `trackID`, `gainDb`, `muted`, `loop`. Apply to the selected native audio group. IDs come from `show`. |
| `removeAudio` | `trackID`. Remove the selected native audio group. |
| `rename` | `title`. A nonempty title up to 1000 characters. |
| `canvas` | `aspectRatio`, `padding`, `backgroundColor`. Ratio: `native`, `16:9`, `9:16`, `1:1`, `4:3`, `3:4`, `21:9`. Padding: 0 to 25 percent. Color: `#RRGGBB`. |

Text and audio placement use the native source-time ruler in seconds, before speed
changes and removed trim ranges. `frame --time` uses rendered output seconds instead.
Transitions use the editor's fade-through-color behavior, not overlapping dissolves.
The schema exposes only implemented operations. Still-image conversion, detached audio,
markers, transform/grade settings and explicit delivery codecs are not part of version 1.

## Results and errors

With `--json`, create/apply/validate/render/frame return a versioned object containing
`path`, `written`, `clipIDs` and `aliases` on stdout. Show always prints project JSON;
schema always prints JSON Schema. Runtime failures return a JSON object on stderr with
`version: 1` and `error: {code, message}`, leaving stdout empty. Invalid edit operations
exit 2; other runtime failures exit 1. Command syntax errors use the standard CLI parser
diagnostic and exit 2. Success exits 0.

Validate checks project structure, source availability and native composition. Empty
projects validate successfully, but need video before rendering. Render exports MP4
using the current native high-quality preset; frame exports a composited PNG. Rendering
honors existing supported project effects, including effects configured in the UI.

## MCP

The running `ed mcp` server registers `edith_studio_edit_schema`,
`edith_studio_edit_create`, `edith_studio_edit_show`, `edith_studio_edit_apply`,
`edith_studio_edit_validate`, `edith_studio_edit_render` and `edith_studio_edit_frame`.
Each takes the usual MCP `arguments` array, containing the same positional arguments and
options as the corresponding CLI command. JSON output is enabled by the transport.
Existing destinations still require an explicit `--overwrite` argument.

```json
{
  "name": "edith_studio_edit_render",
  "arguments": {"arguments": ["/demo/demo.openscreen", "--output", "/demo/demo.mp4"]}
}
```

Native video rendering has a bounded six-hour MCP execution deadline. Other routes keep
the standard 120-second deadline. Output capture stays capped at 4 MiB, and cancellation
continues to terminate the child process group.
