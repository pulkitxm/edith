# `ed capture window`

Opens the macOS window selector, stores the PNG in Recent Captures, and opens
the quick preview.

Usage:

```text
ed capture window [--json]
```

| Option | What it does |
| --- | --- |
| `--json` | Emits the request acknowledgement as JSON. |

Plain output is `window requested`. JSON output is:

```json
{"operation":"capture.window","requested":true}
```

## Where to go next

- [`ed capture`](./README.md)
- [`ed capture area`](./area.md)
- [`ed capture screen`](./screen.md)
- [All `ed` commands](../README.md)
