# `ed database capabilities`

Shows the shared capability report for one saved connection.

```
ed database capabilities <connection-id> [--refresh] [--json]
```

| Argument | Type | Default | What it does |
| --- | --- | --- | --- |
| `connection-id` | UUID | required | Selects the exact saved connection. |

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `--refresh` | flag | off | Requires fresh product and capability discovery instead of accepting a cached report. |
| `--json` | flag | off | Emits one JSON object on stdout. |

The human output names the detected product and version, topology, report
source, every capability with availability and requirement, and each safety
limitation. JSON contains `connectionID`, `source`, and `report`. The report
includes product identity, topology, modules, plugins, capabilities,
permissions, paging modes, mutation modes, transaction modes, cancellation
modes, import and export formats, explain modes, safety limitations, and cache
timestamps.

Unavailable capabilities stay in the report. Their structured reason can name
the category, required version, topology, permissions, extension, and other
constraints. Capability attributes and reason text have already crossed the
broker's bounded redaction layer, and the CLI renders those typed fields
explicitly.

```
ed database capabilities 36fc476b-28f7-4c1a-ae54-4b10d793fd0f
ed database capabilities 36fc476b-28f7-4c1a-ae54-4b10d793fd0f --json
ed database capabilities 36fc476b-28f7-4c1a-ae54-4b10d793fd0f --refresh --json
```

Malformed UUIDs exit 2 without contacting the broker. Broker connection,
authentication, permission, timeout, and transport failures leave stdout empty
and use the documented error exit code.

## Where to go next

- [`ed database connections get`](./connections-get.md)
- [`ed database`](./README.md)
- [All `ed` commands](../README.md)
