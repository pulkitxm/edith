# `ed clipboard clear`

Forgets the whole history.

```
ed clipboard clear [--keep-pinned] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--keep-pinned` | flag | off | Keep pinned entries. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "remaining": 3,
  "removed": 1214
}
```

`removed` is a count here, and `remaining` is what survived, which is 0 without
`--keep-pinned` and the number of pinned entries with it.

There is no confirmation flag on this one: unlike `ed machines rm` or
`ed cleaner clean`, `clear` acts immediately. Orphaned blobs are pruned with it,
so the disk space comes back at once. Clearing an already empty history writes
nothing and reports `cleared 0 entries`, exit 0.

Examples:

```
ed clipboard clear
ed clipboard clear --keep-pinned
ed clipboard clear --json
```

```
$ ed clipboard clear --keep-pinned
cleared 1214 entries
```

## Where to go next

- [`ed clipboard`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
