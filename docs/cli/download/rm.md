# `ed download rm`

Takes one entry out of the queue.

Usage:

```
ed download rm <n> [--yes] [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<n>` | integer, counting from 1 | required | The download to remove, numbered as `ed download ls` numbers it. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--yes` | flag | off | Applies the removal. Without it, only previews the record. |
| `--json` | flag | off | Emits one JSON document on stdout. |

Without `--yes`, `rm` reports what it would remove and does not change the
queue. With `--yes`, it removes the record, never the downloaded file. Use
`ed download cancel` before removing an active entry.

`--json` shape:

```json
{
  "preview": false,
  "remaining": 11,
  "removed": 1
}
```

`removed` counts the records that matched, and `remaining` is what the file
holds afterwards.

Examples:

```
ed download rm 1
ed download rm 1 --yes
ed download rm 4 --yes --json
```

```
$ ed download rm 2 --yes
removed Night Drive
```

Behaviour: the entry is resolved to its persisted ID before mutation, so only
the selected record is removed. An index outside the list exits 3 with the
queue size as the hint. An empty queue exits 4. A confirmed change posts
`downloadQueueChanged`.

## Where to go next

- [`ed download`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
