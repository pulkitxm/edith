# `ed shelf clear`

Empties the shelf.

Usage:

```
ed shelf clear [--json] [--yes]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--yes` | flag | off | Applies the clear. Without it, prints every exact path. |

There are no positional arguments and no way to keep part of the shelf.
Without `--yes`, `clear` previews every indexed path and changes nothing.

`--json` shape:

```json
{
  "removed": 2
}
```

`removed` is how many items were on the shelf before it was emptied.

Examples:

```
ed shelf clear
ed shelf clear --yes --json
```

```
$ ed shelf clear --yes
cleared 2 items
```

Behaviour: `clear` deletes every file the index knows about, then writes an
empty index. Files that are in the shelf folder but not in the index are left
where they are, so a folder that has been edited by hand can still hold
something after a clear. Clearing an already empty shelf is reported as
`cleared 0 items` and exits 0 rather than failing. The `.index.json` file
itself stays, holding `[]`.

## Where to go next

- [`ed shelf`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
