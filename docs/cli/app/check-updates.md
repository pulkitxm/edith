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

The updater belongs to the running Edith app and remains available when its
window is closed. The command is unavailable in development installations that
do not provide a production updater. A waiting request checks for a recorded
result for up to 60 seconds and fails if no result arrives.

`--no-wait` requests the check and returns `"finished": false` immediately. Use
`ed app updates` to inspect the result later.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
