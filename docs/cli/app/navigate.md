# `ed app navigate`

Moves the current window selection to a route without bringing Edith forward.

```
ed app navigate <route> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<route>` | route | none | Where to go, such as `companion/chat` or `machines/<id>/docker`. |
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
ed app navigate companion/chat
ed app navigate docs --json
```

This reads the route you pass and changes the selection in place. It does not
activate Edith or order a window forward. An empty route, or one with an empty
segment, is a usage error, exit 2. A route the window cannot apply exits 1.
The main window process must be running; without it the command exits 4.

## Where to go next

- [`ed app route`](./route.md), read the current route
- [`ed app back`](./back.md), step backward
- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
