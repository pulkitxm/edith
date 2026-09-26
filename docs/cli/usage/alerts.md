# `ed usage alerts`

Shows, for every limit window Edith tracks, the burn rate, the projected cap
time and which limit alert the planner would send right now, with the reason.

```
ed usage alerts [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout |

## `--json` shape

One object. `enabled` is whether limit alerts are switched on,
`jevConfigured` whether a TypeSafe key is saved, and `windows` holds one entry
per tracked window: Codex, Claude, Cursor, then Grok. Claude has a 5-hour
window, a weekly window and Fable. Codex has a 5-hour window and a weekly
window. Cursor has its two billing-cycle pools. Grok has its plan allowance.
Each appears only when the provider reported it and its toggle is on.

```json
{
  "enabled": true,
  "jevConfigured": false,
  "windows": [
    {
      "active": true,
      "alert": "on_pace",
      "body": "Claude 5h is at 72%. At your last 30 minutes' pace you'll hit the cap around 3:40 PM, 1 h 10 m before it resets at 4:50 PM.",
      "burnMinutes": 30,
      "burnPerHour": 24,
      "label": "Claude 5h",
      "percent": 72,
      "projectedCapAt": "2026-09-24T15:40:00Z",
      "provider": "claude",
      "reason": "Your last 30 minutes' pace is 24.0% an hour, reaching the cap 1 h 10 m before the reset",
      "resetsAt": "2026-09-24T16:50:00Z",
      "title": "Claude 5h on pace to cap",
      "window": "session"
    }
  ]
}
```

`alert` is one of `capped`, `almost_capped`, `on_pace`, `headroom`, `outlook`
or `back`, or `null` when nothing is due. `burnPerHour` and `burnMinutes` are
`null` until there is enough history for a rate, and `projectedCapAt` is `null`
when the window is idle or already capped.

## Examples

```
ed usage alerts
ed usage alerts --json
ed usage alerts --json | jq -r '.windows[] | "\(.label): \(.alert // "none") - \(.reason)"'
```

## Behaviour

The command mutates nothing and needs no app. It reads the newest reading and
the last 26 hours of `limits-history.jsonl`, runs the same planner the
background agent runs after every limits poll, and reads what the agent has
already sent from its notification outbox so an alert that already went out
shows as held rather than due again.

The planner works per window. The burn rate is the change in percent over the
last 30 minutes and the last hour for a 5-hour window, taking the lower of the
two, and over the last day for a weekly one. A window counts as active only when
it rose in each of the last three 10-minute blocks (5-hour) or in the last two
hours (weekly), so a short spike followed by a pause never projects anything.
Alerts, highest priority first, at most one per window per poll:

- `capped` at 100%, once per window.
- `almost_capped` at `notifyAlmostCappedPercent`, 90 by default, once per window.
- `on_pace` from 40% up when the active burn reaches the cap at least 15 minutes
  (5-hour) or 6 hours (weekly) before the reset and within 90 minutes or two
  days. It fires again in the same window only if the cap moves at least 30
  minutes (5-hour) or 12 hours (weekly) earlier.
- `headroom` on the last day of a weekly window with half or more unused.
- `outlook` in the morning, at most once a day per weekly window, when the
  window's average daily burn heads for 70% or more.

A window that reached 90% gets a `back` notification scheduled for its reset
time. If the window resets early, `back` goes out immediately instead. Login
problems alert once per failure until the provider answers again, and never
show up here.

With a TypeSafe key saved, the agent asks Jev whether `on_pace`, `headroom` and
`outlook` alerts are worth interrupting for and holds them below 0.32. A held
alert is not marked as sent, so the next check asks again and it goes out once
Jev agrees, for example when you are back at the computer. Jev never holds back
`capped`, `almost_capped`, `back` or login alerts, and this command always shows
the deterministic verdict. When `enabled` is false the
human output ends with a note that alerts are off.

When no provider has ever been recorded the command exits 4 with `no limit
history yet`, hinted with `enable the Agent Usage extension and let Edith poll
once`.

```
$ ed usage alerts
WINDOW         USED  RESETS             BURN     CAP AROUND  ALERT    WHY
Claude 5h      72%   4:50 PM            24.0%/h  3:40 PM     on_pace  Your last 30 minutes' pace is 24.0% an hour, reaching the cap 1 h 10 m before the reset
Claude weekly  64%   Thursday 10:00 AM  0.4%/h   idle        none     idle: no change in the last 2 hours
```

## Where to go next

- [`ed usage limits`](./limits.md), the raw readings
- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
