# `ed agent restart`

Restart Edith's app-owned core services without restarting the app process.

```
ed agent restart [--json]
```

The app cancels and drains its current core requests, stops the old runtime,
and starts a replacement. The window and menu bar keep the same process id.
Subscriptions and background work reconnect to the replacement runtime.

JSON is `{"restarted": true}` after the replacement has started. The command
exits 4 when no matching live core runtime is available. Use
`ed app relaunch --yes` when the whole application needs a fresh process.

## Where to go next

- [`ed agent status`](./status.md), to confirm service state
- [`ed agent`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
