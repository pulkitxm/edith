# `ed database mcp`

Runs the read-only Edith Database MCP server over standard input and output.

```
ed database mcp
```

The command stays in the foreground. Standard input and stdout belong entirely
to MCP protocol traffic, so the command prints no startup banner. Process-level
diagnostics use stderr. Each tool request crosses the authenticated local
Database broker boundary.

| Tool | What it does |
| --- | --- |
| `database_connections` | Lists at most 100 safe connection projections or gets one by UUID. |
| `database_capabilities` | Returns the bounded capability report for one saved connection, optionally refreshing discovery. |

Both tools declare read-only, non-destructive, idempotent, closed-world MCP
annotations. Connection projections omit endpoints, usernames, authentication,
TLS configuration, tunnel details, connection options, secret references, and
authentication sources. Responses preserve the broker status, completeness,
warnings, partial failures, and structured errors.

An MCP client configuration can launch the server directly:

```json
{
  "mcpServers": {
    "edith-database": {
      "command": "ed",
      "args": ["database", "mcp"]
    }
  }
}
```

## Where to go next

- [`ed database connections list`](./connections-list.md)
- [`ed database capabilities`](./capabilities.md)
- [`ed database`](./README.md)
- [All `ed` commands](../README.md)
