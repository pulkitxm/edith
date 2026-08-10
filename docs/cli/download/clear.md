# `ed download clear`

Forgets what has finished.

Usage:

```
ed download clear [--everything] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--everything` | flag | off | Clears what is still queued or running as well. |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments and no `--yes` guard. Without
`--everything` it drops the `done`, `failed` and `interrupted` records and
leaves `queued`, `resolving` and `downloading` alone, which is the safe sweep
after a batch has run. With `--everything` the file is emptied whatever state
things are in. Neither form deletes a downloaded file; only the list is
cleared.

`--json` shape:

```json
{
  "remaining": 2,
  "removed": 9
}
```

Examples:

```
ed download clear
ed download clear --everything
ed download clear --json
```

```
$ ed download clear
cleared 9
```

Behaviour: clearing an already empty queue reports `cleared 0` and exits 0
rather than failing. `downloadQueueChanged` is posted afterwards, so a running
Edith empties its Download sheet to match. Note that `--everything` forgets an
in-flight download without stopping it, exactly as `rm` does.

## Where to go next

- [`ed download`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
