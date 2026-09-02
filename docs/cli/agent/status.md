# `ed agent status`

Reads the background agent's live state over XPC.

```
ed agent status [--json]
```

The table shows the Login Items registration state, the agent's build, its
process id, uptime, resident memory, CPU share since launch, how many
subscribers hold a topic, the store path and the store's schema version. JSON
adds `protocolVersion`, which both sides check on every connection.

The command exits 4 when the agent is not running or refuses the connection.
The agent accepts connections only from code signed with Edith's own team
identifier, so a peer built with a different identity is rejected before any
message is read.

## Where to go next

- [`ed agent jobs`](./jobs.md), for what it is running
- [`ed agent`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
