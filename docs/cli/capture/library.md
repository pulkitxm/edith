# `ed capture library`

Opens the bounded Recent Captures library without starting a new screen
capture.

Usage:

```text
ed capture library [--json]
```

| Option | What it does |
| --- | --- |
| `--json` | Emits the request acknowledgement as JSON. |

Plain output is `library requested`. JSON output is:

```json
{"operation":"capture.library","requested":true}
```

Library cards can copy, save, drag, edit, pin, or delete a PNG. The library
keeps at most 12 captures and prunes older items before its total exceeds
256 MB.

## Where to go next

- [`ed capture`](./README.md)
- [`ed capture area`](./area.md)
- [`ed capture read`](./read.md)
- [All `ed` commands](../README.md)
