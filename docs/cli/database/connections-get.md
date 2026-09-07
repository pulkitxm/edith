# `ed database connections get`

Shows the safe non-secret definition of one saved connection.

```
ed database connections get <connection-id> [--json]
```

| Argument | Type | Default | What it does |
| --- | --- | --- | --- |
| `connection-id` | UUID | required | Selects the exact saved connection. |

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON object on stdout. |

Human output reports identity, product, environment, location, deployment,
read-only policy, production policy, and favorite state. JSON adds namespace
defaults, bounded timeout and pool settings, safe non-secret options, tunnel
configuration, and lifecycle timestamps.

Authentication JSON contains only `kind` and `credentialsConfigured`. TLS JSON
contains mode, verification, server name, and configured booleans. It omits
secret references, authentication sources, resource UUIDs, and private-key
references. The SQLite file access reference is represented only by
`fileAccessConfigured`.

```
ed database connections get 36fc476b-28f7-4c1a-ae54-4b10d793fd0f
ed database connections get 36fc476b-28f7-4c1a-ae54-4b10d793fd0f --json
```

Malformed UUIDs exit 2 without contacting the broker. A valid UUID that is not
saved exits 3.

## Where to go next

- [`ed database connections list`](./connections-list.md)
- [`ed database capabilities`](./capabilities.md)
- [`ed database connections`](./connections.md)
- [All `ed` commands](../README.md)
