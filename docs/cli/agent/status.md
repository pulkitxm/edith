# `ed agent status`

Read the live state of the matching app's background services.

```
ed agent status [--json]
```

The table includes state, build, process id, uptime, resident memory, CPU share,
subscriber count, store path, and schema version. The process id is Edith's own
app process. JSON also includes the service protocol version.

The command uses Edith's authenticated local CLI channel. It exits 4 when the
matching app or its core services are unavailable. Development builds have
separate command endpoints and stores.

## Where to go next

- [`ed agent jobs`](./jobs.md), for what it is running
- [`ed agent`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
