# `ed attention focus start`

Starts one focus session. Starting another while one is active fails without
replacing the existing session.

```
ed attention focus start [--for <duration>] [--name <text>] [--json]
```

The duration defaults to `25m` and accepts positive minute or hour values such as
`90m` or `1.5h`. The name defaults to `Focus`.

## Where to go next

- [`ed attention`](../README.md)
- [`ed attention focus stop`](./stop.md)
