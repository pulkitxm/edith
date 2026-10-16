# `ed app forward`

Moves the window on to the next route in its history.

```
ed app forward [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |

`--json` shape:

```json
{
  "route": "docs",
  "canGoBack": true,
  "canGoForward": false
}
```

Examples:

```
ed app forward
ed app forward --json
```

This reads the history stack and changes the selection in place. It does not
activate Edith or order a window forward. When there is nothing to go forward
to, the command exits 1. The main window process must be running; without it
the command exits 4.

## Where to go next

- [`ed app back`](./back.md), step the other way
- [`ed app route`](./route.md), read the current route
- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
