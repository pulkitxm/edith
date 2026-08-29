# `ed capture screen`

Captures the full main display immediately, stores the PNG in Recent Captures,
and opens the quick preview.

Usage:

```text
ed capture screen [--json]
```

| Option | What it does |
| --- | --- |
| `--json` | Emits the request acknowledgement as JSON. |

Plain output is `screen requested`. JSON output is:

```json
{"operation":"capture.screen","requested":true}
```

## Where to go next

- [`ed capture`](./README.md)
- [`ed capture area`](./area.md)
- [`ed capture window`](./window.md)
- [All `ed` commands](../README.md)
