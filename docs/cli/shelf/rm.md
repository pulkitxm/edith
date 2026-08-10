# `ed shelf rm`

Takes one item off the shelf.

Usage:

```
ed shelf rm <n> [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<n>` | integer, 1 or more | required | The item number from `ed shelf ls`, counting from 1. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There is no `--yes` guard here: `rm` takes effect the moment you run it.

`--json` shape:

```json
{
  "remaining": 1,
  "removed": 2
}
```

`removed` echoes back the number you passed, not an id or a name, and
`remaining` is how many items are left.

Examples:

```
ed shelf rm 1
ed shelf rm 2 --json
```

```
$ ed shelf rm 2
removed notes 2.pdf, 1 left
```

Behaviour: `rm` deletes the shelf's copy outright. It does not go to the Trash,
unlike `ed music rm` and `ed cleaner clean`, and it is not recoverable, so the
copy is gone even though whatever you originally added is untouched. A copy
that is already missing is not an error: the index entry is dropped and the
command still exits 0.

Numbers shift after every removal, because they are positions in a
newest-first list rather than ids. Removing several items means re-reading
`ed shelf ls` between calls, or removing from the highest number downwards.

An index below 1 or above the count exits 3, and `rm` on an empty shelf exits 4
with the same message `path` gives.

## Where to go next

- [`ed shelf`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
