# `ed capture read`

Selects part of the screen, recognizes text and supported codes offline, copies
the configured result, and opens the transient preview.

Usage:

```text
ed capture read [--json]
```

| Option | What it does |
| --- | --- |
| `--json` | Emits the request acknowledgement as JSON. |

Plain output is `screen read requested`. JSON output is:

```json
{"operation":"capture.read","requested":true}
```

The command exits 0 when the request is delivered, 2 for invalid arguments,
and 4 when the extension is off or the menu bar app is not running. Canceling
the selector does not change an already completed command.

`captureCopyMode` controls what is copied. `smart` copies code payloads when
present and otherwise copies OCR text. `text`, `codes`, and `combined` provide
explicit alternatives.

## Where to go next

- [`ed capture`](./README.md)
- [`ed capture screenshot`](./screenshot.md)
- [`ed extensions enable`](../extensions/enable.md)
