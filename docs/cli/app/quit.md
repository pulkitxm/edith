# `ed app quit`

Close Edith's windows, or quit the entire app with `--completely`.

```
ed app quit [--completely] [--yes] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--completely` | flag | off | Quit the app process, menu bar, core services, and extension engines. |
| `--yes` | flag | off | Apply the action; otherwise print a preview. |
| `--json` | flag | off | Emit JSON on stdout. |

Without `--completely`, the menu bar and enabled background work stay in the
same app process after its windows close. `ed app open` shows the window again.
The menu bar's Quit Edith item quits the whole application.

Examples:

```
ed app quit
ed app quit --yes
ed app quit --completely --yes --json
```

A preview reports `applied: false`, `changed: false`, and
`requiresConfirmation: true`. An applied request reports that it was accepted;
the command reply can arrive before the application finishes closing.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
