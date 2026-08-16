# `ed app snapshot`

Captures the app's open windows as PNG files.

```
ed app snapshot [--dir <path>] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--dir` | directory path | `/tmp/edith-snapshots` | Where the images are written. Created if missing; `~` expands. |
| `--json` | flag | off | Emit JSON on stdout. |

`--json` shape:

```json
{
  "files": [
    "/tmp/edith-snapshots/edith.png"
  ]
}
```

Examples:

```
ed app snapshot
ed app snapshot --dir ~/Desktop/edith-shots
ed app snapshot --json
```

The app renders each visible window itself, so no screen-recording permission
is involved and other applications never appear in the output. One PNG per
window, named after the window title (`edith.png`, and `edith-2.png` when two
windows share a title), overwriting a previous file with the same name. Titles
are lowercased, every non-letter or non-number run becomes one hyphen, and an
empty title becomes `window.png`. Files from an older capture whose names are
not reused are left in the directory.
Without `--json` it prints one file path per line. Exits 1 when no visible
window rendered or the destination directory could not be created, and 4 when
the main window process is not running. A write failure for one window is
skipped; the command still succeeds if at least one other window was written.
`ed app reveal` is the way to put the right screen up first.

## Where to go next

- [`ed app reveal`](./reveal.md), choose what the windows show
- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
