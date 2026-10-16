# `ed app diagnostics`

Reads live diagnostics from the menu bar helper.

```
ed app diagnostics [--json]
```

The plain table includes app identity, process id, formatted uptime, idle
wakeups, and bundle path. JSON is an object with `info`, `pid`,
`uptimeSeconds`, `uptime`, and `idleWakeups`; `info` has the same shape as
[`ed app info`](./info.md).

This command needs the helper because uptime and energy counters belong to that
process. It exits 4 when the helper is closed or does not answer within five
seconds. A failure leaves JSON stdout empty.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
