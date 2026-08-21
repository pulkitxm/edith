# `ed attention doctor`

Checks the menu bar helper, native collector setting, browser server setting,
packaged extension resources, and local event store.

```
ed attention doctor [--json]
```

An empty event store is reported as `not ready` but does not make the overall JSON
`ok` false. That state is normal immediately after guided setup. Use the Attention
screen for source installation, permissions, and the browser connection token.

## Where to go next

- [CLI index](../README.md)
- [`ed attention status`](./status.md)
