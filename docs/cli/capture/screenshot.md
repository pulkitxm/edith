# `ed capture screenshot`

Selects part of the screen and opens a lightweight preview with Copy image,
Save, Copy result, safe Open, and Discard actions.

Usage:

```text
ed capture screenshot [--json]
```

| Option | What it does |
| --- | --- |
| `--json` | Emits the request acknowledgement as JSON. |

Plain output is `screenshot requested`. JSON output is:

```json
{"operation":"capture.screenshot","requested":true}
```

The command exits 0 when the request is delivered, 2 for invalid arguments,
and 4 when the extension is off or the menu bar app is not running. The preview
closes after 12 seconds while it is not under the pointer. Save writes a PNG to
`~/Pictures/Edith Captures`.

Command-C copies the primary result, Command-Shift-C copies the alternate text
or image result, Command-S saves, Command-O opens a single safe web code, and
Escape discards the preview.

## Where to go next

- [`ed capture`](./README.md)
- [`ed capture read`](./read.md)
- [`ed permissions`](../permissions/README.md)
- [All `ed` commands](../README.md)
