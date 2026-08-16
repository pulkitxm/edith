# `ed lid-awake battery`

Sets the low-battery percentage below which an active Lid Awake session pauses.

```
ed lid-awake battery <threshold> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<threshold>` | integer `1` through `100`, or `off`, `none`, `disabled` | required | Set the pause threshold, or store 0 to disable the policy. |
| `--json` | flag | off | Emit the stored threshold as JSON. |

The off spellings are case-insensitive. A number outside 1 through 100, a
fraction or other text exits 1 without changing the stored value.

```
ed lid-awake battery 20
ed lid-awake battery off
ed lid-awake battery disabled --json
```

Human output is `battery auto-pause = 20%` or `battery auto-pause = off`. JSON
contains only the stored integer:

```json
{
  "batteryThreshold": 20
}
```

This is a preference write, so it works with Edith closed and posts
`settingsChanged` for a running app. It does not start or stop Lid Awake by
itself. While running on battery, the engine pauses below the threshold and
retains `requestedActive: true`; after AC power is connected and the battery is
at least five percentage points above the threshold, it resumes. Setting the
threshold to off resumes a session that is currently battery-paused.

## Where to go next

- [`ed lid-awake`](./README.md), the rest of this group
- [`ed lid-awake status`](./status.md), see the current pause state
- [`ed config get lidAwakeBatteryThreshold`](../config/get.md), read the same preference
- [All `ed` commands](../README.md)
