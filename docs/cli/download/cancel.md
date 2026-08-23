# `ed download cancel`

Stops active downloads and keeps their records available to retry.

Usage:

```
ed download cancel [<n>] [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<n>` | integer, counting from 1 | all active records | Cancels only the record numbered this way by `ed download ls`. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There is no `--yes` guard because cancellation is retryable. With a number,
only that `queued`, `resolving` or `downloading` record becomes `interrupted`.
Without a number, every active record changes. Finished entries stay unchanged
and cannot be targeted.

`--json` shape:

```json
{
  "appRunning": true,
  "appNotified": true,
  "cancelled": 1,
  "records": [
    {
      "detail": "Cancelled",
      "id": "58F41E66-1D3E-4C0C-9D89-63DC3C082D79",
      "index": 2,
      "kind": "audio",
      "queuedAt": "2026-08-07T19:12:44Z",
      "state": "interrupted",
      "title": "https://youtu.be/dQw4w9WgXcQ",
      "url": "https://youtu.be/dQw4w9WgXcQ"
    }
  ]
}
```

Each record has the same stable shape as `ls --json`, including its persisted
ID and final interrupted state. `cancelled` counts changed records.
`appRunning` reports whether the main app was present, and `appNotified`
reports whether the targeted cancellation was sent to it. Both remain distinct
because changing a queued record does not necessarily terminate a process.

Examples:

```
ed download cancel
ed download cancel 2
ed download cancel --json
```

```
$ ed download cancel
cancelled 3
```

```
$ ed download cancel 2
cancelled https://youtu.be/dQw4w9WgXcQ
```

With Edith closed:

```
$ ed download cancel
cancelled 3
Edith was not running, so queued entries were marked interrupted
```

Behaviour: with nothing in flight the command writes `nothing is downloading`
to stderr, changes no file, and exits 0; under `--json` that note is not
printed and stdout carries `"cancelled": 0` instead. Otherwise, when the main
Edith app is running, it posts `requestDownloadCancel` with the selected stable
record ID, which terminates yt-dlp only when that record is in flight. The
shared operation marks the selected unfinished records as
`interrupted` and posts `downloadQueueChanged`, so the app and CLI show the same
retryable history. With Edith closed, only the persisted transition is needed.

## Where to go next

- [`ed download`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
