# `ed clipboard rm`

Forgets one entry and deletes the blob behind it.

```
ed clipboard rm <index> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<index>` | integer, from 1 | required | The entry number, counting from 1. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "remaining": 1216,
  "removed": 3
}
```

`removed` here is the index that was removed, not a count, which is the opposite
of what the same key means under `clear`. `remaining` is how many entries the
history holds afterwards.

Removal also prunes orphaned blobs, so the file under `blobs/` goes with the
entry unless another entry references the same content. This is not a Trash
move and there is no undo: the bytes are gone.

Examples:

```
ed clipboard rm 3
ed clipboard rm 1 --json
```

```
$ ed clipboard rm 3
removed entry 3, 1216 left
```

Numbers shift after a removal, so removing several entries by number means
re-reading `ls` between each one, or reading `id` out of `--json` first and
working from that.

## Where to go next

- [`ed clipboard`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
