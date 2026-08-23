# `ed download clear`

Forgets what has finished.

Usage:

```
ed download clear [--everything] [--yes] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--everything` | flag | off | Clears what is still queued or running as well. |
| `--yes` | flag | off | Applies the clear. Without it, only reports how many records match. |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments. Without `--everything`, the preview counts
the `done`, `failed` and `interrupted` records and
leaves `queued`, `resolving` and `downloading` alone, which is the safe sweep
after a batch has run. Add `--yes` to apply it. With `--everything --yes`, the
file is emptied whatever state things are in. Neither form deletes a file.

`--json` shape:

```json
{
  "preview": true,
  "remaining": 11,
  "removed": 0,
  "wouldRemove": 9
}
```

Examples:

```
ed download clear
ed download clear --yes
ed download clear --everything --yes --json
```

```
$ ed download clear --yes
cleared 9
```

Behaviour: previewing or clearing an empty queue reports zero and exits 0. A
confirmed change posts `downloadQueueChanged`, so a running Edith reloads the
same queue. Cancel active work before using `--everything --yes`.

## Where to go next

- [`ed download`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
