# `ed color copy`

Copies one numbered swatch from the colour history to the macOS pasteboard.
Numbers match `ed color ls`, with 1 as the newest colour.

Usage:

```text
ed color copy <index> [--format <f>] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<index>` | integer, 1 through the history count | required | Selects the swatch shown at that position by `ed color ls`. |
| `--format <f>` | `hex`, `rgb`, `hsl`, `swiftUI`, `nsColor` | `colorPickerCopyFormat`, falling back to `hex` | Chooses the exact text written to the pasteboard. |
| `--json` | flag | off | Emits one JSON document on stdout. |

JSON reports the shared `operation`, numbered `index`, persistent swatch `id`,
chosen `format`, exact copied `value`, and `copied: true`.

```json
{
  "copied": true,
  "format": "hex",
  "id": "00000000-0000-0000-0000-000000000123",
  "index": 1,
  "operation": "color.copy",
  "value": "#4C6EF5"
}
```

Examples:

```text
ed color copy 1
ed color copy 3 --format swiftUI
ed color copy 1 --format rgb --json
```

The command uses the same formatters and pasteboard operation as clicking a
Recent Colors swatch in Settings or selecting one from the menu bar context
menu. It does not need Edith running. An empty history exits 4 with a prompt to
pick a colour. An index outside the current history or an unknown format exits
3 without changing the pasteboard.

## Where to go next

- [`ed color`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
