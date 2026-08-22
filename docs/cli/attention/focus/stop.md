# `ed attention focus stop`

Finishes the active focus session and appends it to focus history.

```
ed attention focus stop [--json]
```

The JSON object includes `id`, `name`, `startedAt`, `endedAt`, and
`elapsedSeconds`. `end` is an alias for `stop`. The command fails if no session is
active.

## Where to go next

- [`ed attention`](../README.md)
- [`ed attention focus start`](./start.md)
