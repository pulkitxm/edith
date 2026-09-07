# `ed agent logs`

Prints recent agent lines from the unified log.

```
ed agent logs [--last 1h] [--json]
```

The agent logs to the `com.pulkit.edith.agent` subsystem. `--last` takes any
window the `log` tool accepts, such as `10m`, `2h` or `1d`. JSON is an array of
lines.

This reads the system log rather than the agent, so it works even when the
agent is not running.

## Where to go next

- [`ed agent status`](./status.md), for the live state
- [`ed agent`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
