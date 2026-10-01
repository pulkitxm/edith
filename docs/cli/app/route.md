# `ed app route`

Prints the route of the window that owns navigation history.

```
ed app route [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |

`--json` shape:

```json
{
  "route": "companion/chat",
  "canGoBack": true,
  "canGoForward": false
}
```

Examples:

```
ed app route
ed app route --json
```

This reads the selection and does not change it. It does not activate Edith
or order a window forward. The main window process must be running; without
it the command exits 4. If that process has not registered a route yet, the
command exits 1.

## Where to go next

- [`ed app navigate`](./navigate.md), move to another route
- [`ed app back`](./back.md), step backward
- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
