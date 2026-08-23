# `ed download cancel`

Stops active downloads and keeps their records available to retry.

Usage:

```
ed download cancel [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments and no `--yes` guard. Every `queued`,
`resolving` and `downloading` record becomes `interrupted`. Finished entries
stay unchanged.

`--json` shape:

```json
{
  "appRunning": true,
  "cancelled": 3,
  "stoppedRunning": true
}
```

`cancelled` counts the records marked interrupted. `appRunning` says whether
the main Edith app was there to be asked, and `stoppedRunning` says whether it
was asked, so `false` means the queue was emptied without a transfer being
stopped. With nothing to cancel, `stoppedRunning` is always `false` while
`appRunning` still reports what it found.

Examples:

```
ed download cancel
ed download cancel --json
```

```
$ ed download cancel
cancelled 3
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
Edith app is running, it posts `requestDownloadCancel`, which terminates the
active yt-dlp process. The shared operation marks unfinished records as
`interrupted` and posts `downloadQueueChanged`, so the app and CLI show the same
retryable history. With Edith closed, only the persisted transition is needed.

## Where to go next

- [`ed download`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
