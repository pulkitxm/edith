# `ed download rm`

Takes one entry out of the queue.

Usage:

```
ed download rm <n> [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<n>` | integer, counting from 1 | required | The download to remove, numbered as `ed download ls` numbers it. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There is no `--yes` guard: `rm` takes effect the moment you run it. It removes
the record, never the downloaded file, so removing a `done` entry forgets the
history and leaves the track in your music folder. Removing a `downloading`
entry does not stop the download; use `ed download cancel` for that.

`--json` shape:

```json
{
  "remaining": 11,
  "removed": 1
}
```

`removed` counts the records that matched, and `remaining` is what the file
holds afterwards.

Examples:

```
ed download rm 1
ed download rm 4 --json
```

```
$ ed download rm 2
removed Night Drive
```

Behaviour: the entry is matched by its URL and its queued timestamp together,
so an identical link queued at a different moment survives. Two URLs queued in
the same `add` share a timestamp, so a link passed twice in one command is
removed by one `rm` and `removed` reports 2. An index outside the list exits 3
with the size of the queue as the hint; running it against an empty queue exits
4. The file is rewritten and `downloadQueueChanged` is posted either way.

## Where to go next

- [`ed download`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
