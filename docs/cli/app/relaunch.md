# `ed app relaunch`

Restart the matching Edith app so new permission grants and a new build take
effect in its window, menu bar, core services, and extension engines.

```
ed app relaunch [--yes] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--yes` | flag | off | Quit and relaunch Edith; otherwise print a preview. |
| `--json` | flag | off | Emit JSON on stdout. |

The matching CLI performs the restart. A development app's bundled CLI reaches
that worktree's app. Use its full path when another Edith installation is also
running.

```
ed app relaunch
ed app relaunch --yes
ed app relaunch --yes --json
```

The restart waits for the old app to leave before starting its replacement. It
reports a failure if the app cannot stop or start. The launch does not activate
the app or take focus.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
