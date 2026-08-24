# `ed app quit`

Quits the Edith main window and leaves the menu bar running.

```
ed app quit [--yes] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--yes` | flag | off | Send the quit request. Without it, print the plan only. |
| `--json` | flag | off | Emit JSON on stdout. |

Without `--yes`, `--json` describes the safe preview:

```json
{
  "action": "quit",
  "applied": false,
  "changed": false,
  "requested": false,
  "targets": ["com.pulkit.edith"]
}
```

With `--yes`, `applied`, `changed`, and `requested` are `true`.

Examples:

```
ed app quit
ed app quit --yes
ed app quit --yes --json
```

Without `--yes` it prints the main app bundle id and leaves both processes
untouched. With `--yes` and without `--json` it prints `quit requested`. The
confirmed action is guarded on the main window rather than the helper, because
there is nothing to quit otherwise: with the window closed it exits 4 with
`quit needs the Edith main window to be open`, hint `open Edith from the menu
bar, then retry`.

It quits less than the menu bar's own Quit item does. The menu item posts the
same request and then terminates the helper as well; `ed app quit --yes` posts
only the request, so the menu bar app survives and `ed app open` brings the
window back.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
