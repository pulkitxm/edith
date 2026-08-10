# `ed machines workspace equalize`

Evens out every split in a workspace.

Usage:

```
ed machines workspace equalize [--workspace <workspace>] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--workspace` | name, id, or unambiguous name prefix | the current workspace | Which workspace to level. |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments, and there is no way to equalize one split
rather than all of them.

`--json` shape: the workspace, in the shape `panes` prints. The ratios it just
changed are not part of that document, so the JSON before and after are
identical.

Examples:

```
ed machines workspace equalize
ed machines workspace even
ed machines workspace equalize --workspace Fleet --json
```

```
$ ed machines workspace equalize
evened out 3 panes
```

Behaviour: `equalize` walks the tree and gives every child of every split an
equal share, which is the equal-square button in the Workspace toolbar. It is
the only verb here that touches ratios, and ratios are the only thing it
touches: no pane moves, nothing is retargeted, focus does not change.

A workspace whose root is a single pane has no split to level, so the command
does nothing to the layout and still reports `evened out 1 panes`. It writes the
file and posts the notification either way, so it is never a pure read even when
it changes nothing.

## Where to go next

- [`ed machines workspace`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
