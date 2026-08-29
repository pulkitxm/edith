# `ed capture area`

Opens the macOS area selector, stores the PNG in Recent Captures, and opens the
quick preview.

Usage:

```text
ed capture area [--json]
```

| Option | What it does |
| --- | --- |
| `--json` | Emits the request acknowledgement as JSON. |

Plain output is `area requested`. JSON output is:

```json
{"operation":"capture.area","requested":true}
```

The preview can copy or drag the PNG, save it with the configured folder and
filename template, edit, pin, delete, copy recognized content, or open one safe
web code.

## Where to go next

- [`ed capture`](./README.md)
- [`ed capture window`](./window.md)
- [`ed capture library`](./library.md)
- [All `ed` commands](../README.md)
