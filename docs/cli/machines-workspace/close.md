# `ed machines workspace close`

Closes a pane.

Usage:

```
ed machines workspace close <pane> [--workspace <workspace>] [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<pane>` | integer, 1 to the pane count | required | Which pane to close, counting from 1. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--workspace` | name, id, or unambiguous name prefix | the current workspace | Which workspace to close a pane in. |
| `--json` | flag | off | Emits one JSON document on stdout. |

There is no `--yes` guard: the pane goes the moment you run it, along with every
tab in it.

`--json` shape: the workspace after the close, in the shape `panes` prints.

Examples:

```
ed machines workspace close 3
ed machines workspace close 1 --workspace Fleet
ed machines workspace close 2 --json
```

```
$ ed machines workspace close 3
closed pane 3; 2 left
```

Behaviour: this is Close Pane in the same pane menu, which the app greys out on
a single-pane workspace. Closing a pane removes it from the tree and then tidies
the tree around it. A split left with one child collapses into that child, and
a split nested inside another on the same axis is flattened into it, with ratios
multiplied through so the panes that remain keep their relative sizes. The
practical effect is that pane numbers after a close are not simply the old ones
minus one; run `panes` again.

If the pane you closed was the focused one, focus moves to the first pane. If it
was the maximized one, nothing is maximized any more.

The last pane cannot be closed, because a workspace with no panes has nothing to
draw. That check runs before the pane number is even looked at, so on a
single-pane workspace every `close` reports the same thing and exits 1,
including `close 9`:

```
$ ed machines workspace close 1
error: Compare has one pane left, and a workspace needs one
hint: remove the whole thing with `ed machines workspace rm`
```

## Where to go next

- [`ed machines workspace`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
