# `ed download cancel`

Stops what is downloading and empties the rest of the queue.

Usage:

```
ed download cancel [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments and no `--yes` guard. Everything not
finished, meaning `queued`, `resolving` and `downloading`, is removed from the
queue. Finished entries stay: this is the mirror image of `clear`, which drops
the finished ones and keeps the rest.

`--json` shape:

```json
{
  "appRunning": true,
  "cancelled": 3,
  "stoppedRunning": true
}
```

`cancelled` counts the records taken out of the queue. `appRunning` says whether
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
Edith was not running, so the queue was emptied without stopping yt-dlp
```

Behaviour: with nothing in flight the command writes `nothing is downloading`
to stderr, changes no file, and exits 0; under `--json` that note is not
printed and stdout carries `"cancelled": 0` instead. Otherwise, when the main
Edith app is running, it posts `requestDownloadCancel`, which the app's
downloader observes: it terminates the yt-dlp it has running and stops taking
new work. `ed` then removes the unfinished records and posts
`downloadQueueChanged`, so the app re-reads the emptied file and finds nothing
left to start. With the main app closed there is no downloader to ask and
nothing of Edith's is running, so `ed` empties the queue and says so on stderr:
`Edith was not running, so the queue was emptied without stopping yt-dlp`. That
note is on the human path only, and the exit code is 0 either way. The Download
sheet's Cancel All button runs the same cancel in the app but keeps the entries
as `interrupted`, which is why the sheet can retry them and
`ed download cancel`, which removes the records, leaves nothing to retry.

## Where to go next

- [`ed download`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
