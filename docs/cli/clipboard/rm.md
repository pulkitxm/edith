# `ed clipboard rm`

Forgets one entry and deletes the blob behind it.

```
ed clipboard rm <index> [--json] [--yes]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<index>` | integer, from 1 | required | The entry number, counting from 1. |
| `--json` | flag | off | Emit JSON on stdout. |
| `--yes` | flag | off | Apply the removal. Without it, preview the exact entry. |

```json
{
  "action": "remove clipboard entry",
  "applied": true,
  "changed": true,
  "id": "c8ca5dfe8a9a4d24",
  "index": 3,
  "preview": "copied text",
  "remaining": 1216,
  "removed": 3,
  "targets": ["c8ca5dfe8a9a4d24"]
}
```

`removed` here is the index that was removed, not a count, which is the opposite
of what the same key means under `clear`. `remaining` is how many entries the
history holds afterwards.

Without `--yes`, the command reports the exact entry id, index, and preview
without changing the index or blob. Removal prunes orphaned blobs, so the file
under `blobs/` goes with the entry unless another entry references the same
content. This is not a Trash move and there is no undo after confirmation.

Examples:

```
ed clipboard rm 3
ed clipboard rm 1 --yes --json
```

```
$ ed clipboard rm 3 --yes
removed entry 3, 1216 left
```

Numbers shift after a removal, so removing several entries by number means
re-reading `ls` between each one, or reading `id` out of `--json` first and
working from that.

## Where to go next

- [`ed clipboard`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
