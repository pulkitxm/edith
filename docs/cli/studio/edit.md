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
| `ed studio edit render <project> --output <file.mp4>` | Renders the project to MP4. |
| `ed studio edit frame <project> --time <seconds> --output <file.png>` | Saves one composited frame at an output timeline time. |
| `ed studio edit contact-sheet <project> --time <seconds> --output <file.png>` | Creates a labeled sheet of composited output frames. Repeat `--time` for each frame. |

All commands accept `--json` for structured runtime errors. Create, list, clone, apply,
validate, render, frame and contact-sheet also use it for structured results.
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

## Where to go next

- [`ed studio tools`](./tools.md), for file-based media tools
- [All `ed` commands](../README.md)
