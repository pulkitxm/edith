# `ed download clear`

Forgets what has finished.

Usage:

```
ed download clear [--yes] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--yes` | flag | off | Applies the clear. Without it, only reports how many records match. |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments. The preview counts the `done`, `failed` and
`interrupted` records and leaves `queued`, `resolving` and `downloading` alone.
Add `--yes` to apply it. To remove active work safely, cancel it first and then
clear it. Neither command deletes a downloaded file.

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
ed download cancel && ed download clear --yes --json
```

```
$ ed download clear --yes
cleared 9
```

Behaviour: previewing or clearing an empty queue reports zero and exits 0. A
confirmed change posts `downloadQueueChanged`, so a running Edith reloads the
same queue. Clear never removes a queued or running record.

## Where to go next

- [`ed download`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
