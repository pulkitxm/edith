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
  "action": "clear shelf",
  "applied": true,
  "changed": true,
  "remaining": 0,
  "removed": 2,
  "targets": [
    "/Users/pulkit/Library/Application Support/Edith/Shelf/report.pdf",
    "/Users/pulkit/Library/Application Support/Edith/Shelf/notes.txt"
  ]
}
```

`removed` is how many items were on the shelf before it was emptied. Preview
output has the same shape with `applied: false`, `changed: false`, and no
`remaining` field.

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
