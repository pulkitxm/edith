# `ed app open`

Opens Edith's main window.

```
ed app open [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |

`--json` shape:

```json
{
  "action": "open",
  "requested": true
}
```

Examples:

```
ed app open
ed app open --json
```

Without `--json` it prints `open requested`. The guard is on the menu bar
helper, not the window: the helper is what receives the request and launches or
activates the main app, so `ed app open` exits 4 when the helper is closed even
though what it opens is the window. It is the counterpart to `ed app quit`. When
neither process is running, `ed app relaunch` is what starts Edith from cold.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
