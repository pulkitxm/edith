# `ed app quit`

Quits the Edith main window and leaves the menu bar running.

```
ed app quit [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |

`--json` shape:

```json
{
  "action": "quit",
  "requested": true
}
```

Examples:

```
ed app quit
ed app quit --json
```

Without `--json` it prints `quit requested`. This is the one menu-bar-facing
verb that is guarded on the main window rather than the helper, because there is
nothing to quit otherwise: with the window closed it exits 4 with `quit needs
the Edith main window to be open`, hint `open Edith from the menu bar, then
retry`.

It quits less than the menu bar's own Quit item does. The menu item posts the
same request and then terminates the helper as well; `ed app quit` posts only
the request, so the menu bar app survives and `ed app open` brings the window
back.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
