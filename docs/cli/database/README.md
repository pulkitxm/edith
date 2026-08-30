# `ed database`

`ed database` is the noninteractive read surface for saved database connection
definitions and their detected capabilities. Every request crosses the same
authenticated local broker boundary as the Database page. The CLI never reads
the metadata store or opens a database driver directly.

The bare command runs `ed database connections`, which in turn runs
`ed database connections list`.

## Commands

| Command | What it does |
| --- | --- |
| `ed database` | Runs the default connection listing. |
| [`ed database connections`](./connections.md) | Lists connections by default or selects one by UUID. |
| [`ed database connections list`](./connections-list.md) | Lists bounded saved connection summaries with server-side filters. |
| [`ed database connections get`](./connections-get.md) | Shows one saved connection without credentials or secret references. |
| [`ed database capabilities`](./capabilities.md) | Shows the shared capability report, optionally refreshing discovery. |
| [`ed database mcp`](./mcp.md) | Serves bounded read-only connection and capability tools over MCP stdio. |

## Safety boundary

JSON is assembled field by field. It does not encode the stored connection
definition wholesale. Authentication output contains only its kind and whether
credentials are configured. TLS resources are booleans, not local resource
identifiers. Secret references and authentication sources are never printed.

The live sender starts or reconnects to the Database broker and verifies the
peer before sending a request. A broker timeout, unavailable runtime, unsafe
peer, or interrupted response exits 4 and writes diagnostics only to stderr.
Commands are not replayed automatically.

The direct list, get, and capabilities commands print payloads only when the
broker marks them complete. Partial, sampled, estimated, truncated, or stale
results exit 1 with an empty stdout so automation cannot mistake incomplete
data for a complete result. Warnings for an otherwise complete result remain
visible on stderr. MCP tool responses preserve their explicit status,
completeness, warnings, and partial failures in the structured response.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The requested connection or capability data printed. |
| 1 | The broker returned an invalid response or an internal database failure. |
| 2 | A UUID, list bound, or other structural request argument was invalid. |
| 3 | A requested connection, product, environment, or order name was not found. |
| 4 | The broker or requested database capability was unavailable. |

## Where to go next

- [All `ed` commands](../README.md)
- [CLI conventions and contracts](../conventions.md)
