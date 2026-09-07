# `ed agent restart`

Stops the background agent so launchd starts a fresh one.

```
ed agent restart [--json]
```

The agent is a KeepAlive LaunchAgent, so terminating it is how you restart it.
Subscriptions are dropped and every client reconnects on its next call. Use
this after installing a new build if the agent is still reporting the old one,
or when a job is wedged.

JSON is `{"restarted": true}`. The command exits 4 when the agent is not
running, since there is nothing to restart.

## Where to go next

- [`ed agent status`](./status.md), to confirm the new build
- [`ed agent`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
