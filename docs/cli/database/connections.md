# `ed database connections`

Groups read-only saved connection inspection.

```
ed database connections
ed database connections list
ed database connections get <connection-id>
```

With no subcommand it runs `list`. `list` and its `ls` alias use the same
server-side metadata search contract. `get` requires the exact UUID emitted by
a listing.

## Commands

- [`ed database connections list`](./connections-list.md)
- [`ed database connections get`](./connections-get.md)

## Where to go next

- [`ed database`](./README.md)
- [All `ed` commands](../README.md)
