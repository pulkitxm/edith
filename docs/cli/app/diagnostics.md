# `ed app diagnostics`

Reads live diagnostics from the matching Edith app process.

```
ed app diagnostics [--json]
```

The plain table includes app identity, process id, formatted uptime, idle
wakeups, core service state, and bundle path. JSON is an object with `info`, `pid`,
`uptimeSeconds`, `uptime`, `idleWakeups`, `agent`, and `extensions`; `info` has the same shape as
[`ed app info`](./info.md).

The counters belong to the app process. Core diagnostics use that same process
id, while `extensions` lists active extension identifiers. The command exits 4
when the matching app is unavailable.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
