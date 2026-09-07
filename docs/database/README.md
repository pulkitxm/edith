# Database extension

Database is a native workbench for relational, key-value, document, search, and analytical databases. It exposes the same validated operations through the Edith interface, the `ed database` command family, and a local MCP server.

The first supported product set is:

- PostgreSQL
- MySQL
- MariaDB
- SQLite
- Redis
- Valkey
- MongoDB
- Elasticsearch
- OpenSearch
- ClickHouse

Support is product-specific. A shared protocol does not imply that metadata, types, permissions, administration, or failure behavior are interchangeable. Every live connection produces a capability report based on the detected product, version, topology, modules or plugins, and current account permissions.

## Product principles

1. A user always sees the active connection, environment, namespace, and mutation mode before execution.
2. The interface, CLI, and MCP server call one typed command executor. Validation, capability checks, safety checks, redaction, pagination, cancellation, and result envelopes live there.
3. Browsing is lazy and server-bounded. The client never presents a partially loaded client-side filter or sort as complete.
4. Relational rows, Redis values, MongoDB documents, search documents, and ClickHouse results retain model-native workflows.
5. Destructive work starts with a preview. Execution requires a short-lived confirmation token bound to the exact target and effect.
6. Credentials remain in Keychain. Saved connection files contain references and non-secret settings only.
7. Unsupported actions are hidden or disabled with a capability reason. They are never simulated through an unsafe fallback.
8. Network loss, cancellation, and a failed connection remain isolated from every other open session.

## Workbench areas

The Database section contains:

- A searchable connection list with groups, tags, favorites, recent use, health, read-only state, and production labels.
- A lazy object explorer with breadcrumbs, favorites, scope refresh, permission states, and direct navigation between related objects.
- A tabbed workspace for data, query, command, definition, plan, monitoring, import, export, and visualization tasks.
- A bounded dynamic grid with server pagination, projection, filtering, sorting, selection, staged edits, detail inspection, and accessible keyboard behavior.
- Model-specific workspaces for Redis and Valkey keyspaces, MongoDB documents and pipelines, Elasticsearch and OpenSearch indices, and ClickHouse analytical structures.
- An operation center for progress, cancellation, partial failures, history, and safe retry guidance.

At wide widths the explorer, workspace, and inspector can be visible together. At narrower widths they become resizable focused columns, sheets, or tabs. Important actions move into overflow menus instead of disappearing. Grid columns scroll within the grid, while identifiers can remain pinned and full records remain available in a detail view.

## Documentation map

- [Research](research.md) records inspected products and the design lessons adopted or rejected.
- [Capabilities](capabilities.md) defines the supported feature surface and honest exclusions.
- [Architecture](architecture.md) defines contracts, data flow, adapters, safety, CLI, and MCP.
- [Experience](experience.md) defines workflows, responsive behavior, accessibility, and visualization.
- [Verification](verification.md) defines the real-product, large-data, failure, performance, and automation strategy.
- [Delivery](delivery.md) defines the pull request stack and completion gates.

## Resource limits

Defaults are deliberately conservative and configurable within hard safety limits:

| Resource | Default | Hard limit or behavior |
| --- | ---: | --- |
| Data page | 200 records | 2,000 records |
| Projected fields | Visible plus identity | 512 fields |
| Large text preview | 64 KiB | Explicit inspector load up to 8 MiB |
| Binary preview | Metadata only | Explicit chunked load up to 8 MiB |
| Metadata page | 200 objects | 1,000 objects |
| Schema inference | 1,000 documents | 10,000 documents |
| Redis scan count hint | 500 keys | 5,000 keys per request |
| Export batch | 2,000 records | Adaptive, memory-bounded |
| Import batch | 1,000 records | Adapter and server bounded |
| MCP result page | 100 records | 500 records |
| Operation history | 500 entries | Oldest completed entries evicted |
| Concurrent connections | 8 | 32 with per-connection pools |
| Query timeout | 30 seconds | Explicit override required |

Counts are estimated by default when exact counting would require a full scan. Continuation tokens are opaque, scoped, expiring, and invalid after a connection or query definition changes.

## Safety summary

Saved connections can be read-only, mutation-enabled, or production-protected. Read-only enforcement occurs in the command executor and adapter, not only in the interface. Production mutations require a preview even for a single record. Unrestricted updates and deletes, truncation, drops, permission changes, session termination, ClickHouse mutations, and search delete-by-query use stronger confirmation language.

Preview responses contain the connection, environment, product, namespace, target, predicate or selection, normalized statement or request, estimated effect, transaction behavior, rollback availability, synchronous or asynchronous behavior, warnings, and an expiring token. The token is signed locally and binds those fields. Editing any field invalidates it.

The executor never silently retries a non-idempotent operation. Logs, errors, history, structured output, MCP results, screenshots, and evidence pass through the same secret redactor.
