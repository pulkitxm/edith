# `ed studio edit`

[Back to `ed studio`](./README.md)

Edit native `.openscreen` video projects and render them without opening a window.
Media stays local. The commands use the same project format and render pipeline as
the native timeline editor. Running `ed studio edit` prints the edit-plan schema.

## Commands

| Command | What it does |
| --- | --- |
| `ed studio edit schema` | Prints the versioned edit-plan JSON Schema. |
| `ed studio edit create <project> [--title <title>]` | Creates an empty project. |
| `ed studio edit show <project>` | Prints project JSON, including IDs for later edits. |
| `ed studio edit list <directory>` | Lists native projects with their identities, titles and clip counts. |
| `ed studio edit clone <project> --output <copy.openscreen> --title <title>` | Copies an edit with a new project identity while preserving its original-media references. |
| `ed studio edit apply <project> --plan <file> [--output <project>] [--dry-run]` | Validates and atomically applies every operation in a plan. |
| `ed studio edit validate <project>` | Checks structure, source availability and native composition. |
| `ed studio edit render <project> --output <file> [--codec <codec>]` | Delivers H.264/HEVC MP4 or a ProRes MOV master, with a measured report. |
| `ed studio edit render-audio <project> --output <file> [--container wav\|aiff\|m4a]` | Delivers the native audio mix with a measured sample-frame count. |
| `ed studio edit frame <project> --frame <index> --output <file.png>` | Saves an exact output frame; alternatively use `--time <seconds>`. |
| `ed studio edit contact-sheet <project> --time <seconds> --output <file.png>` | Creates a labeled sheet of composited output frames. Repeat `--time` for each frame. |

All commands accept `--json` for structured runtime errors. Create, list, clone, apply,
validate, render, render-audio, frame and contact-sheet also use it for structured results.
Schema and show always print JSON.
Write commands require `--overwrite` to replace an existing destination. Apply without
`--output` replaces its input, so it requires `--overwrite` except during dry-run.
Create destination directories before running a command.

## Example

```sh
ed studio edit create demo.openscreen --title "Synthetic demo" --json
ed studio edit apply demo.openscreen --plan edit.json --dry-run --json
ed studio edit apply demo.openscreen --plan edit.json --overwrite --json
ed studio edit validate demo.openscreen --json
ed studio edit render demo.openscreen --output demo.mp4 --json
ed studio edit render-audio demo.openscreen --output mix.wav --json
ed studio edit frame demo.openscreen --time 0.25 --output preview.png --json
ed studio edit list . --json
ed studio edit clone demo.openscreen --output alternate.openscreen --title "Alternate cut" --json
ed studio edit contact-sheet demo.openscreen --time 0 --time 0.25 --columns 2 --cell-width 320 --output review.png --json
```

Save this plan as `edit.json` beside a local video named `synthetic.mov`:

```json
{
  "version": 1,
  "operations": [
    {"addMedia": {"path": "synthetic.mov", "name": "intro"}},
    {"rename": {"title": "Synthetic demo"}}
  ]
}
```

Relative media paths resolve beside the plan file. Use `ed studio edit schema` for
supported operations and their required fields. Plans are limited to 4 MiB and 1000
operations; input and serialized output projects are limited to 32 MiB.

Dry-run validates the whole plan without writing files. Failed operations preserve
the input. Concurrent applies serialize, and CLI and native saves reject stale
revisions with `project_changed`. Output destinations cannot replace source media,
wallpapers, image annotations or other render dependencies.

Project listing reports unreadable or invalid files individually. A clone has its
own identity but references the same source files; it does not package media.
Contact-sheet times use rendered output seconds after trim and speed changes.
Each tile reports its selected frame index and timestamp. Use 1 to 64 times,
1 to 8 columns, and a cell width from 64 to 1920 pixels. The completed PNG report
includes its dimensions and SHA-256 checksum.

## Delivery settings

`ed studio edit render` accepts `--codec`, `--bit-rate`, `--key-frame-interval`,
`--audio-codec`, `--audio-bit-rate`, `--audio-sample-rate`, `--audio-channels`,
`--color-space` and `--require-hardware`. Codec values are `h264`, `hevc`, `hevc10`,
`proRes422`, `proRes422HQ` and `proRes4444`. H.264/HEVC require `.mp4`; ProRes requires
`.mov`. Omitted color space follows the validated project settings.

`ed studio edit render-audio` accepts `--container wav|aiff|m4a`, `--sample-rate`,
`--channels` and `--bit-rate`. WAV/AIFF use 24-bit PCM; M4A uses AAC. Both delivery
commands accept `--progress` for bounded stderr updates, preserve `written` and
`path` in their JSON result, and add a measured video or audio report. SIGINT and
SIGTERM cooperatively cancel delivery and preserve an existing destination.

`ed studio edit frame` requires exactly one of `--frame` or `--time`. Frame indices
are zero-based output frames. Times are output seconds, snapped to the preceding
frame using the exact rational cadence. JSON returns the selected `frame` and `time`.

See [native project delivery](./delivery.md) for every setting, default, unit,
report field and MCP route.

Both delivery commands also accept `--start-frame INDEX --end-frame INDEX` for
a half-open interval on the unchanged original output timeline. Supply both
bounds or neither. Transitions, captions and music retain their original timing;
encoded timestamps start at zero. The measured report adds `range` with the
selected project frame bounds and rational frame rate.

## Where to go next

- [`ed studio tools`](./tools.md), for file-based media tools
- [All `ed` commands](../README.md)
