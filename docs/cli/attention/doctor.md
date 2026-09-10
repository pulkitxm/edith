# `ed attention doctor`

Checks the Attention master switch, background agent, native collector setting, browser server setting,
packaged extension resources, and local event store.

```
ed attention doctor [--json]
```

An accessible empty event store is healthy. An unavailable event store makes the overall JSON
`ok` false, so a connection failure cannot look like an empty history. Use the Attention
screen for source installation, permissions, and the browser connection token.

## Where to go next

- [CLI index](../README.md)
- [`ed attention status`](./status.md)
