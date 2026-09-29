# Headless video editing

`ed studio edit` edits the same `.openscreen` project files and uses the same native
render pipeline as the video editor. It runs locally without opening an editor window.
Original media remains in place. Projects reference absolute source paths.

See [original media CLI](video-media-cli.md) for identities, capture chronology,
source provenance, and multi-project clip-occurrence reuse audits.

## Commands

```sh
ed studio edit schema
ed studio edit create demo.openscreen --title "Synthetic demo" --json
ed studio edit apply demo.openscreen --plan edit.json --dry-run --json
ed studio edit apply demo.openscreen --plan edit.json --overwrite --json
ed studio edit show demo.openscreen --json
ed studio edit validate demo.openscreen --json
ed studio edit render demo.openscreen --output demo.mp4 --json
ed studio edit render demo.openscreen --output master.mov --codec proRes422HQ --progress --json
ed studio edit render-audio demo.openscreen --output mix.wav --json
ed studio edit frame demo.openscreen --time 0.25 --output preview.png --json
ed studio edit frame demo.openscreen --frame 15 --output exact-frame.png --json
ed studio edit list . --json
ed studio edit clone demo.openscreen --output alternate.openscreen --title "Alternate cut" --json
ed studio edit contact-sheet demo.openscreen --time 0 --time 0.25 --output review.png --json
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
unknown operations and unsupported versions are rejected, including unknown or missing
fields inside settings, effects and individual keyframes. Plans are limited to 4 MiB
and 1000 operations. Project files are limited to 32 MiB and 10000 clips or assets.
The 32 MiB limit also applies to the final serialized output, including pretty-print
formatting, during both apply and dry-run.

Operations run in order. `addMedia.name`, `addStill.name` and `split.rightName` define plan-local aliases
for newly created clips. Later operations can use either an alias or a persisted clip ID
from `show`. Result JSON returns aliases and the final ordered clip IDs. Aliases are not
saved as project IDs. Relative media paths resolve beside the plan file, including when
the project lives elsewhere. Absolute paths and `~` paths are also supported.

| Operation | Fields and semantics |
| --- | --- |
| `addMedia` | `path`, `name`. Probe and append a local file with a native-decodable video track. Records actual dimensions, codec, frame cadence and available color metadata. |
| `addStill` | `path`, `name`, `duration`. Append an original ImageIO-readable still. Duration is positive source seconds, at most seven days. |
| `stillDuration` | `clipID`, `duration`. Set a still clip's source duration from its current trimmed start. Does not change its original file or the asset's import duration. |
| `videoSettings` | `settings`. Replace explicit canvas pixels, rational output fps and project color space. All nested fields are required. |
| `visualEffects` | `clipID`, `effects`. Replace framing, focal anchor, grading and source-time transform keyframes. All nested fields are required. |
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
| `canvas` | `aspectRatio`, `padding`, `backgroundColor`. Ratio: `native`, `16:9`, `9:16`, `1:1`, `4:3`, `3:4`, `21:9`. Writes explicit pixels once, preserving fps and color. Presets preserve the current longest edge; `native` reads the first current clip's displayed dimensions once. Padding: 0 to 25 percent. Color: `#RRGGBB`. |

Text and audio placement use the native source-time ruler in seconds, before speed
changes and removed trim ranges. `frame --time` uses rendered output seconds instead,
snapped to the preceding output frame using the exact rational cadence.
Frame extraction requires exactly one of `--time SECONDS` or `--frame INDEX`.
`--frame` is a zero-based output-frame index, evaluated with the composition's exact
rational frame duration. Result JSON includes the selected `frame` and its `time` in
output seconds. An index at or beyond the frame count is rejected.
Transitions use the editor's fade-through-color behavior, not overlapping dissolves.
The schema exposes only implemented edit-plan operations. Detached audio, marker edits
and explicit delivery codecs use their separate interfaces.

## Original stills and visual settings

Save this plan beside a local image named `synthetic.png`:

```json
{
  "version": 1,
  "operations": [
    {"videoSettings": {"settings": {
      "width": 1920, "height": 1080,
      "frameRateNumerator": 60000, "frameRateDenominator": 1001,
      "colorSpace": "rec709"
    }}},
    {"addStill": {"path": "synthetic.png", "name": "cover", "duration": 5}},
    {"stillDuration": {"clipID": "cover", "duration": 8}},
    {"visualEffects": {"clipID": "cover", "effects": {
      "framing": "fill", "focalX": 0.5, "focalY": 0.5,
      "exposure": 0, "brightness": 0, "contrast": 1, "saturation": 1,
      "keyframes": [
        {"time": 0, "scale": 1, "positionX": 0, "positionY": 0,
         "rotation": 0, "interpolation": "smooth"},
        {"time": 8, "scale": 1.045, "positionX": 0.02, "positionY": 0,
         "rotation": 2, "interpolation": "linear"}
      ]
    }}}
  ]
}
```

Still assets retain their original paths and decode at original resolution for native
rendering. EXIF orientation is applied. Extending or trimming a still does not create a
replacement movie. Preview downsampling does not change the stored asset.

Canvas dimensions are even integers from 2 to 16384 pixels. Frame-rate numerator and
denominator are positive 32-bit integers whose quotient is from 1 to 240. The frame
duration is exactly denominator/numerator seconds. For 120 fps, use numerator `120`
and denominator `1`. Adding, removing or reordering clips does not change these settings.
Color space is `rec709` or `displayP3`; PNG frames and native delivery honor that choice.
Delivery can explicitly override it with `--color-space`.

`visualEffects` is a full replacement, not a partial patch. `framing` is `fit` or `fill`.
Focal coordinates range from 0 to 1, measured from the left and top. Exposure is in
stops from -10 to 10; brightness is -1 to 1; contrast and saturation are 0 to 4 with
identity at 1. Grading uses the same native Core Image pipeline as the editor.

Keyframe times are strictly increasing source seconds, so trimming, changing speed and
skipping source ranges preserve the animation's source anchors. Scale is a positive
multiplier up to 100, applied after fit/fill. Position is in canvas-width/height fractions,
from -100 to 100; positive X moves right and positive Y moves down. Rotation is degrees,
positive counterclockwise, bounded to ±36000. `linear` or `smooth` interpolation on a
keyframe controls the interval to the next keyframe. Values hold before the first and
after the last keyframe. Use `keyframes: []` to clear animation.

## Results and errors

With `--json`, create/apply/validate/render/render-audio/frame return a versioned object containing
`path`, `written`, `clipIDs` and `aliases` on stdout. Show always prints project JSON;
schema always prints JSON Schema. Runtime failures return a JSON object on stderr with
`version: 1` and `error: {code, message}`, leaving stdout empty. Invalid edit operations
exit 2; other runtime failures exit 1. Command syntax errors use the standard CLI parser
diagnostic and exit 2. Success exits 0.

Validate checks project structure, source availability and native composition. Empty
projects validate successfully, but need video before rendering. Render uses the native
reader/writer delivery pipeline; frame exports a composited PNG. Rendering
honors existing supported project effects, including effects configured in the UI.

## Native delivery

`render` accepts the following settings. Frame cadence, canvas dimensions and duration
come from the project composition, after speed and trim edits.

| Flag | Values / default |
| --- | --- |
| `--codec` | `h264` (default), `hevc`, `hevc10`, `proRes422`, `proRes422HQ`, `proRes4444` |
| `--bit-rate` | Video bits/second, 100000 to 1000000000; default 40000000; unused for ProRes |
| `--key-frame-interval` | Maximum frames between keyframes, 1 to 10000; default 120; unused for ProRes |
| `--audio-codec` | `aac` or `pcm`; defaults to PCM for ProRes, AAC otherwise; PCM requires ProRes |
| `--audio-bit-rate` | AAC bits/second, 32000 to 320000; default 320000; mono maximum 256000 |
| `--audio-sample-rate` | 44100, 48000 (default), or 96000; 96000 requires PCM |
| `--audio-channels` | 1 or 2 (default) |
| `--color-space` | `rec709` or `displayP3`; omitted uses project/composition color, then Rec.709 |
| `--require-hardware` | Fail if hardware encoding is unavailable; H.264/HEVC only |
| `--progress` | Opt-in bounded progress on stderr |

H.264/HEVC destinations require `.mp4`; ProRes requires `.mov`. HEVC Main 10 and
ProRes use high-precision rendering buffers. Unsupported formats fail without replacing
an existing destination. Color conversion and output tags use the selected color space.

`render-audio` accepts `--container wav|aiff|m4a` (default `wav`),
`--sample-rate 44100|48000|96000` (default `48000`), `--channels 1|2` (default `2`),
and `--bit-rate` (default `320000`). WAV/AIFF encode 24-bit PCM; M4A encodes AAC
and supports only 44100/48000 Hz. Mono AAC requires at most 256000 bits/second.
The output extension must match the selected container. Audio export includes the
mixed timeline's leading silence, gaps and tail, with measured sample-frame counts.

```sh
ed studio edit render demo.openscreen --output delivery.mp4 --codec hevc10 \
  --bit-rate 60000000 --key-frame-interval 60 --color-space displayP3 --progress --json
ed studio edit render-audio demo.openscreen --output mix.aiff --container aiff \
  --sample-rate 96000 --channels 2 --progress --json
```

Result JSON retains `version`, `path`, `written`, `clipIDs` and `aliases`. Video delivery
adds `videoReport`: `width`, `height`, `duration` in output seconds, `frameCount`,
`frameRateNumerator`, `frameRateDenominator`, `videoCodec`, `videoBitRate`,
`bitsPerComponent`, `colorPrimaries`, `transferFunction`, `audioCodec`,
`audioSampleRate`, `audioChannels`, `bytes` and `sha256`. Unavailable optional
measurements are omitted. `videoBitRate` is measured bits/second, not the requested target.
Audio delivery instead adds `audioReport`: `codec`, optional `bitsPerSample`,
`duration` in seconds, `sampleRate` in Hz, `channels`, sample `frames`, `bytes`, `sha256`.
Reports describe the completed file and are returned only after atomic publication.

With `--progress --json`, stderr receives at most 101 newline-delimited objects such as
`{"version":1,"event":"progress","percent":42}`. Updates increase monotonically;
100 means publication completed. Stdout remains exactly one final result document.
Without `--json`, progress is human-readable. Without `--progress`, progress is silent.
On a failure after progress begins, the final stderr line is the error object.

SIGINT and SIGTERM cancel the native task cooperatively, remove temporary files and
preserve an existing destination before publication. Cancellation leaves stdout empty,
emits error code `cancelled` and exits 130 for SIGINT or 143 for SIGTERM.

### Output-frame ranges

Both `render` and `render-audio` accept `--start-frame INDEX --end-frame INDEX`.
Supply both or neither. The interval is half-open: the start frame is included and
the end frame is excluded. Bounds must satisfy `0 <= start < end <= frameCount`.
These indices refer to the original rendered project timeline, after speed and trim
edits, using the composition's exact rational frame duration.

```sh
ed studio edit render demo.openscreen --output excerpt.mov --codec proRes422HQ \
  --start-frame 45 --end-frame 81 --progress --json
ed studio edit render-audio demo.openscreen --output excerpt.wav \
  --start-frame 45 --end-frame 81 --json
```

The renderer evaluates the unchanged original composition, including transitions,
captions and the audio mix, then selects the requested interval. Output timestamps
begin at zero. Music phase and any leading silence remain aligned to the selected
project interval. No project file or clip timing is changed.

A range delivery adds `range` inside `videoReport` or `audioReport`, with
`startFrame`, `endFrame`, `frameRateNumerator` and `frameRateDenominator`.
The surrounding report still measures the actual encoded frame count, duration,
format, bytes and checksum. For example, frames `45..<81` at `60000/1001` fps
select 36 video frames spanning 0.6006 seconds. At 48000 Hz the audio report contains
28829 sample frames, with duration rounded to the nearest audio sample.
If the last project frame is partial, a range ending at the frame count ends at the
original composition duration. Omit range flags to deliver the complete composition.

MCP accepts the same range flags through each delivery tool's `arguments` array.
Source protection, overwrite rules, progress, cancellation and codec options apply
to range delivery exactly as they do to full delivery.

## MCP

The running `ed mcp` server registers `edith_studio_edit_schema`,
`edith_studio_edit_create`, `edith_studio_edit_show`, `edith_studio_edit_apply`,
`edith_studio_edit_validate`, `edith_studio_edit_render`, `edith_studio_edit_render_audio`
and `edith_studio_edit_frame`.
Each takes the usual MCP `arguments` array, containing the same positional arguments and
options as the corresponding CLI command. JSON output is enabled by the transport.
Existing destinations still require an explicit `--overwrite` argument.

```json
{
  "name": "edith_studio_edit_render",
  "arguments": {"arguments": ["/demo/demo.openscreen", "--output", "/demo/demo.mp4"]}
}
```

Native video and audio rendering and media operations have a six-hour MCP execution
deadline. Other routes keep
the standard 120-second deadline. Output capture stays capped at 4 MiB, and cancellation
continues to terminate the child process group. MCP returns the final report; optional
child-process stderr progress does not alter the result JSON.

## Project copies and visual review

`list DIRECTORY` returns a path-sorted JSON array with project identity, title and clip
count. Unreadable project files have an `error` entry, allowing valid neighbors to remain
visible. Listing does not load source media or change any project.

`clone PROJECT --output COPY --title TITLE` creates an independent project identity while
preserving the complete edit, clip IDs and original-media references. The source project
cannot be its own clone destination, even with `--overwrite`. This copies the project
document, not its media files or any external source reservations.

`contact-sheet PROJECT --time SECONDS ... --output REVIEW.png` renders a labeled PNG grid
through the same native composition as video export. Times are output seconds, after
trim and speed changes, snapped to the preceding output frame. The JSON report includes
the exact selected frame numbers and times, dimensions and SHA-256 checksum. Each frame
is labeled with its frame number and output time in the image.

Use `--columns` for 1 to 8 columns and `--cell-width` for a maximum thumbnail dimension
from 64 to 1920 pixels. Labels can widen a narrow thumbnail's cell. Defaults are 4 columns
and 320 pixels. A sheet supports 1 to 64 frames
and at most 64 million pixels. Invalid times or failed rendering leave an existing
destination intact. Source images and project files cannot be review destinations.

These operations are also registered as `edith_studio_edit_list`,
`edith_studio_edit_clone`, and `edith_studio_edit_contact_sheet` in the MCP server.
