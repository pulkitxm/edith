# `ed app check-updates`

Asks the running app to run a Sparkle check now, waits for the answer, and
reports it.

```
ed app check-updates [--json] [--no-wait]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |
| `--no-wait` | flag | off | Return as soon as the request is sent, collapsing the wait from 60 seconds to 0.1. |

`--json` shape once the app has answered:

```json
{
  "detail": null,
  "finished": true,
  "outcome": "updateFound",
  "requested": true,
  "version": "0.0.28"
}
```

`outcome` is `upToDate`, `updateFound` or `failed`, and falls back to `unknown`
if the app answers without one. `version` carries the version Sparkle found and
is `null` on the other outcomes; `detail` carries the failure text and is `null`
unless the check failed.

With `--no-wait`, the usual answer is that nothing came back in time, which is
reported rather than treated as an error:

```json
{
  "finished": false,
  "requested": true
}
```

Examples:

```
ed app check-updates
ed app check-updates --json
ed app check-updates --no-wait
```

Without `--json` it prints the outcome alone, `upToDate`, or the outcome and the
version, `updateFound 0.0.28`, and with `--no-wait` and no answer it prints
`update check requested`.

Sparkle lives in the main window, so this exits 4 with `check-updates needs the
Edith main window to be open` when only the menu bar is running. The wait is 60
seconds; after the first second `ed` prints `waiting for Edith to answer...` on
stderr, which keeps stdout to the one JSON document.

Silence at the end of those 60 seconds is exit 4, not a false success. `ed`
diagnoses which kind of silence it was: `Edith is not running, so it cannot
answer for the update check` when the helper is gone, and otherwise `Edith did
not answer for the update check in time`, with the hint that the running app may
predate this command. Two ordinary situations produce that second message: a
build whose Sparkle updater never started does not listen for the request at
all, and a check that is already in flight is dropped rather than queued.

`--no-wait` never fails that way. It still waits 0.1 seconds and still reports a
reply that lands inside it, but a silent app is reported as
`"finished": false` and exit 0, which makes it the right form for a script that
only wants the check kicked off.

Whatever the outcome, the app records the check in its own log, so
`ed app updates` shows it afterwards even when `ed` gave up waiting.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
