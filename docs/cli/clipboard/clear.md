# `ed clipboard clear`

Forgets the whole history.

```
ed clipboard clear [--keep-pinned] [--json] [--yes]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--keep-pinned` | flag | off | Keep pinned entries. |
| `--json` | flag | off | Emit JSON on stdout. |
| `--yes` | flag | off | Apply the clear. Without it, print the exact entry ids. |

```json
{
  "applied": false,
  "changed": false,
  "remaining": 3,
  "removed": 1214,
  "targets": ["entry-id-1", "entry-id-2"]
}
```

`removed` is a count here, and `remaining` is what survived, which is 0 without
`--keep-pinned` and the number of pinned entries with it.

Without `--yes`, the command reports the exact entry ids and changes neither
the index nor its blobs. A confirmed clear deletes only those ids. Orphaned
blobs are pruned with it, so the disk space comes back at once.

Examples:

```
ed clipboard clear
ed clipboard clear --keep-pinned --yes
ed clipboard clear --json
```

```
$ ed clipboard clear --keep-pinned --yes
cleared 1214 entries
```

## Where to go next

- [`ed clipboard`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
