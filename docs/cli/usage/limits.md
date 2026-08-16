# `ed usage limits`

Prints the most recent rate limit observation for each provider Edith tracks.

```
ed usage limits [--refresh] [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--refresh` | flag | off | Asks the app to poll the providers again and waits up to 20 seconds for it to say it did, before reading the file. Fails when nothing answers |
| `--json` | flag | off | Emit JSON on stdout |

## `--json` shape

A top-level array, one object per provider that has ever been recorded, in the
fixed order `codex` then `claude`. `session` and `weekly` are each either an
object or `null`.

```json
[
  {
    "label": "Codex",
    "observedAt": "2026-08-08T16:39:59Z",
    "provider": "codex",
    "session": null,
    "weekly": {
      "percent": 0,
      "resetsAt": "2026-08-15T16:39:59Z",
      "resetsInSeconds": 604797.62
    }
  },
  {
    "label": "Claude",
    "observedAt": "2026-08-08T16:39:58Z",
    "provider": "claude",
    "session": {
      "percent": 30,
      "resetsAt": "2026-08-08T19:50:00Z",
      "resetsInSeconds": 11402.481
    },
    "weekly": {
      "percent": 61,
      "resetsAt": "2026-08-13T08:00:00Z",
      "resetsInSeconds": 400798.117
    }
  }
]
```

## Examples

```
ed usage limits
ed usage limits --json
ed usage limits --refresh
ed usage limits --json | jq -r '.[] | select(.provider == "claude") | .session.percent'
```

## Behaviour

Without `--refresh` the command mutates nothing and needs no app: it reads the
tail of `limits-history.jsonl` and reports the last line it finds for each
provider. Only the final 8 KB of that file is read, so a provider whose newest
row has scrolled out of that window is treated as never seen and is left out of
the output entirely.

`percent` is what the provider reported, stored rounded to one decimal place.
`resetsAt` is the reset time the provider gave, or `null` when it gave none, and
`resetsInSeconds` is computed at print time from your clock, so it goes negative
once the reset moment has passed. The human table shows the session reset as a
coarse duration instead, `3h 10m` or `2d 4h`, clamped at zero, and a `-` in any
column the provider has not reported.

`--refresh` is the refresh button on the rate limit cards. It needs the menu bar
app and exits 4 with `refreshing the rate limits needs the Edith menu bar app to
be running` when Edith is closed. The reply it waits for is only posted when a
poll actually succeeds, so a provider that is failing to answer costs you the
full 20 seconds and then the command fails rather than printing the old numbers:
exit 4 with `Edith did not answer for refreshing the rate limits in time`, or
with `the extension behind refreshing the rate limits is off` when
`tabUsageEnabled` is false. After one second of waiting `ed` prints `waiting for
Edith to answer...` once, on stderr.

The listener goes up before the request goes out, so an app that answers within
the same instant cannot beat it and a poll that worked is never reported as
silence. The numbers printed afterwards are read from the file rather than out
of the reply.

Even a successful refresh does not guarantee a newer `observedAt`: the app
appends a history row only when the values differ from the previous one, so
polling twice inside a quiet window leaves the timestamp where it was.

When no provider has ever been recorded the command exits 4 with `no limit
history yet`, hinted with `enable the Agent Usage extension and let Edith poll
once`. That check comes after the refresh, so a `--refresh` the app answers on a
fresh install reports the emptiness afterwards if nothing landed.

```
$ ed usage limits
PROVIDER  SESSION  WEEKLY  SESSION RESETS  OBSERVED
Codex     -        0.0%    -               2026-08-08T16:39:59Z
Claude    30.0%    61.0%   3h 10m          2026-08-08T16:39:58Z
```

## Where to go next

- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
