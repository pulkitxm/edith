# `ed machines workspace rm`

Forgets a workspace.

Usage:

```
ed machines workspace rm <workspace> [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<workspace>` | name, id, or unambiguous name prefix | required | Which workspace to delete. Case-insensitive. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There is no `--yes` guard here, unlike `ed machines rm`: this takes effect the
moment you run it.

`--json` shape, its own shape rather than the one the other whole-workspace
verbs share:

```json
{
  "remaining": 1,
  "removed": "Compare"
}
```

`removed` is the name of what went, and `remaining` is how many workspaces are
left in the file.

Examples:

```
ed machines workspace rm Compare
ed machines workspace rm comp --json
```

```
$ ed machines workspace rm Compare
removed Compare
```

Behaviour: `rm` deletes the layout outright. Nothing is moved to a trash and
there is no undo, so a workspace you built pane by pane is worth recreating with
a `new` plus a few `split`s rather than fetching back.

Removing the current workspace moves the pointer to whatever is now first in the
file; removing any other leaves the pointer alone. Removing the last one leaves
an empty store, at which point every verb except `ls` and `new` exits 4 until
you make one again.

## Where to go next

- [`ed machines workspace`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
