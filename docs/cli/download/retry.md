# `ed download retry`

Puts a failed or interrupted entry back into the queue.

Usage:

```
ed download retry <n> [--json]
ed download retry --all [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<n>` | integer, counting from 1 | none | The download to retry, numbered as `ed download ls` numbers it. Optional, but required unless `--all` is passed. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--all` | flag | off | Retries everything that failed or was interrupted. |
| `--json` | flag | off | Emits one JSON document on stdout. |

Only `failed` and `interrupted` entries can be retried; retrying sets them back
to `queued` and leaves everything else alone. Naming an entry in any other
state exits 1 and says which state it is in, rather than silently doing
nothing. Passing neither a number nor `--all` also exits 1. `--all` on a queue
with nothing to retry is not an error: it reports 0 and exits 0.

`--json` shape:

```json
{
  "retried": 2
}
```

Examples:

```
ed download retry 3
ed download retry --all
ed download retry --all --json
```

```
$ ed download retry 1
error: download 1 is done, so there is nothing to retry
```

Behaviour: `retry` rewrites `downloads.json` when something changed, and posts
`downloadQueueChanged` either way, so a running Edith picks the work up at once
rather than waiting for its next look at the file. Retrying
by number matches on the entry's URL rather than on its position, so if the
same link failed twice, `ed download retry 3` re-queues both copies and
`retried` says 2. The "Edith is not running" note applies here too, on the
human path only.

## Where to go next

- [`ed download`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
