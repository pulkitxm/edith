# `ed agent jobs`

Lists the jobs the background agent schedules.

```
ed agent jobs [--json]
```

Each row carries the job id, its current phase, its trigger, its cadence and
how many subscribers hold its topic. A job with an ambient cadence runs with no
window open. A job with a live cadence speeds up while a page is subscribed and
falls back to ambient when the last subscriber goes away. A job with neither
runs only on demand.

JSON adds `ambientSeconds`, `liveSeconds`, `power`, `runCount` and `lastError`.

Phases are `idle`, `running`, `paused`, `off` and `failed`. `off` means the
ability that owns the job is disabled. `paused` means a power policy or the
battery preference is holding it.

## Where to go next

- [`ed agent status`](./status.md), for the process itself
- [`ed agent`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
