# Database architecture

## Boundary and dependency direction

Database introduces a shared `EdithDatabase` library. The application, CLI, and MCP entry point depend on it. The library depends on `EdithKit` for application paths and established secure storage behavior, plus selected database drivers. It does not depend on SwiftUI or ArgumentParser.

```text
Database views       ed database commands       MCP tools
       |                      |                     |
       +---------------- typed requests ------------+
                              |
                   DatabaseCommandExecutor
                              |
          validation, policy, capabilities, history
                              |
                    DatabaseAdapterRegistry
                              |
     SQL  |  key-value  |  document  |  search  |  analytics
                              |
                    product drivers and HTTP
```

No presentation adapter contains driver logic. Product checks are confined to adapter registration and capability discovery. Views select behavior by capability identifiers and model-specific contracts.

## Canonical request path

Every operation follows the same path:

1. Decode a versioned typed request.
2. Resolve a saved or ephemeral connection without exposing its secret.
3. Validate target scope, parameters, page bounds, timeouts, and mutation intent.
4. Resolve or refresh the product capability report.
5. Enforce read-only, production, permission, and capability policies.
6. Create a stable operation record.
7. Execute through the selected adapter with cancellation and deadline propagation.
8. Stream or page typed values with backpressure.
9. Redact errors and history before returning them.
10. Complete the operation record with metrics, warnings, partial failures, and a continuation when present.

The executor is an actor. It owns the connection registry, live sessions, operation tracker, confirmation service, and history service for the process. Each session is independently isolated and an adapter must never hold a global mutable current connection.

## Core contracts

### Connection definition

A connection definition contains:

- Stable identifier, display name, product hint, group, tags, color, favorite state, and environment label.
- Host endpoints or a local file path, port, username, namespace defaults, deployment mode, and product-specific non-secret options.
- TLS mode, server-name override, CA reference, client-certificate reference, and client-key reference.
- Optional Edith machine tunnel definition with machine identifier, remote endpoint, loopback bind, and managed local port.
- Authentication kind and Keychain secret references.
- Connection timeout, operation timeout, pool size, idle timeout, and keepalive policy.
- Read-only and production-protection policies.
- Created, updated, last-tested, and last-used timestamps.

The on-disk metadata store is a versioned SQLite database in WAL mode. It holds connection definitions, groups, tags, favorites, saved queries, redacted history, and migrations with safe multi-process transactions. Secrets are stored as Keychain generic-password items under a Database-specific service. Deleting or duplicating a connection updates secrets intentionally and transactionally with registry persistence.

### Product identity and capabilities

`DatabaseProductIdentity` reports family, product, semantic version when known, distribution, topology, server identifier, modules or plugins, and compatibility notes.

`DatabaseCapabilityReport` contains:

- Supported operation identifiers with limits and option schemas.
- Unavailable operation identifiers with a stable reason category and human explanation.
- Product, version, topology, permission, module, and license constraints.
- Paging modes, mutation modes, transaction modes, cancellation modes, import and export formats, and explain modes.
- Current account permissions when they can be discovered safely.
- Safety limitations and server-side limits.
- Discovery timestamp and expiry policy.

Reports are cached per live session and explicitly invalidated after reconnect, privilege changes, extension or plugin changes, and relevant administration commands.

### Values and records

`DatabaseValue` preserves database meaning rather than coercing everything to strings. Cases cover null, missing, boolean, signed and unsigned integers, decimal text, floating point, string, binary summary, date, time, timestamp with zone context, UUID, array, object, and product-specific typed text.

Rows and documents contain a stable identity only when the adapter can prove one. Identity may be a primary or unique key, MongoDB `_id`, search `_id` with concurrency metadata, or a Redis key with type context. Tables without a stable identity remain browsable, but single-row editing requires an explicit predicate preview.

Binary and large values carry size, type, digest when available, and a bounded preview. Loading the complete value is a separate cancellable request.

### Paging and streaming

`DatabasePageRequest` contains page size, continuation, projection, typed filters, stable sorts, and a consistency preference. `DatabasePage` contains records, column or field descriptors, a next continuation, completeness, truncation reasons, count metadata, query timing, and warnings.

Adapters choose one of:

- Keyset continuation for stable relational order.
- Server cursor for MongoDB and supported SQL workflows.
- Redis SCAN cursor with partial-result semantics.
- Point-in-time plus `search_after` for search engines.
- Streaming response with a bounded page cut for ClickHouse.
- Offset only for small or explicitly requested result sets where product behavior makes it appropriate.

Continuations are signed envelopes containing no credentials. They bind connection, target, normalized query, order, projection, and expiry. The executor rejects cross-connection or modified-query reuse.

### Operations

An operation record contains a stable identifier, kind, state, connection and target context, start and finish timestamps, progress, deadline, cancellation support, retry classification, page and byte counts, warnings, partial failures, and redacted error.

States are queued, running, cancelling, succeeded, failed, cancelled, and partiallySucceeded. Progress can be determinate or indeterminate. Cancellation is cooperative and also invokes the product cancellation mechanism when available. A timeout follows the same path but receives a timeout error category.

Completed operation history is bounded and persisted without result payloads or secrets. Active operations remain in memory. A non-idempotent operation is never retried automatically.

### Errors

Errors use stable categories:

- invalidRequest
- connectionFailed
- authenticationFailed
- tlsFailed
- tunnelFailed
- permissionDenied
- unsupported
- readOnlyViolation
- confirmationRequired
- confirmationInvalid
- conflict
- timeout
- cancelled
- server
- network
- decoding
- partialFailure
- resourceLimit
- internalFailure

The public envelope includes category, safe message, optional product code, target context, retry guidance, partial-result state, and bounded safe details. Raw driver errors remain private and are redacted before logging.

## Adapter protocols

`DatabaseAdapter` creates and tests sessions from resolved connection material. It declares a family and accepted product hints.

`DatabaseSession` provides identity discovery, capability discovery, health, metadata roots, child metadata pages, description, raw command execution, data browsing, operations, and disconnect.

Model-specific session protocols extend that boundary:

- `RelationalDatabaseSession`: dialect, catalogs and schemas, row identity, parameterized SQL, transactions, mutation planning, definitions, plans, sessions, locks, and maintenance.
- `KeyValueDatabaseSession`: cursor scans, typed value reads and writes, TTL, collection operations, topology, server statistics, slow log, and bounded Pub/Sub inspection.
- `DocumentDatabaseSession`: document query, aggregation, schema sampling, validation, index management, sessions, transactions, change streams, and topology.
- `SearchDatabaseSession`: query DSL, point-in-time traversal, mappings, settings, bulk operations, asynchronous tasks, aggregations, templates, pipelines, and topology.
- `AnalyticalDatabaseSession`: streaming query, system metadata, partitions, parts, plans, query log, running queries, asynchronous mutations, and data-flow metadata.

Adapters return capability-driven common descriptors, not UI models. Product-specific details live in typed property bags with registered schemas so CLI and MCP can expose them without losing meaning.

## Product adapters

### PostgreSQL

PostgresNIO provides parameterized execution, TLS, streaming rows, cancellation, and pooling. Metadata queries cover databases, schemas, relations, columns, constraints, indexes, routines, types, extensions, policies, replication, activity, locks, statistics, storage, configuration, and maintenance state. Version and permission gates are derived from `server_version_num`, catalog availability, and privilege checks.

### MySQL and MariaDB

MySQLNIO provides the native protocol and parameter binding. Product detection uses server version and product variables before choosing separate MySQL or MariaDB dialect and metadata behavior. Connection pooling is supplied by the shared session layer. Information Schema and product catalogs drive metadata and capabilities.

### SQLite

GRDB provides local SQLite access, transactions, cancellation hooks, and typed values. SQLite connections use file bookmarks or explicit paths, never a network tunnel. Metadata derives from `sqlite_schema`, pragma table functions, compile options, and the runtime version.

### Redis and Valkey

RediStack provides RESP execution and pipelining for standalone servers. Redis and Valkey are detected separately from INFO and command capability discovery. Browsing always uses SCAN. Sentinel and Cluster topology are discovered through their native commands and capability-gated. Collection reads and mutations are bounded by ranges or cursor-like slices.

### MongoDB

MongoKitten provides the native protocol, BSON, cursors, aggregation, bulk writes, sessions, transactions, change streams, and GridFS primitives. Deployment and feature gates come from hello responses, wire versions, build information, topology, privileges, and command probes.

### Elasticsearch and OpenSearch

The search adapter uses `URLSession` with incremental response decoding and product-specific request builders. Root headers and payload, version, nodes, features, plugins, and permission responses distinguish Elasticsearch and OpenSearch. Point-in-time plus `search_after` is preferred for deep browsing. Scroll is reserved for export and batch processing.

### ClickHouse

The ClickHouse adapter uses the HTTP interface with streamed formats. Product metadata comes from version functions and system tables. The adapter exposes MergeTree structures, parts, partitions, replicas, clusters, dictionaries, projections, indexes, query log, running queries, and mutation state. ALTER mutations are asynchronous operations, never row-editor commits.

## Mutation safety

Mutations are two-phase commands:

1. A preview request is normalized, capability-checked, and assigned an effect digest.
2. The response contains the exact context, request representation, effect estimate, warnings, rollback properties, and a short-lived signed token.
3. The apply request repeats the normalized operation and supplies the token.
4. The executor recomputes the digest, checks expiry and one-time use, then executes.

The signing key is generated once and kept in Keychain. Tokens can cross process boundaries for CLI preview and apply, but are scoped to the local account and expire after five minutes. Applying a token consumes it. Interface dialogs never manufacture confirmation state locally.

Predicates are mandatory for bulk update and delete unless the request explicitly selects the complete object and uses the strongest confirmation level. Parameter values remain separate from generated SQL or request bodies. Identifier quoting belongs to each dialect.

Search optimistic updates bind sequence number and primary term when available. MongoDB updates bind `_id` and optional observed fields. Relational updates bind a stable key and, when possible, an observed version or original values. Conflicts return a structured conflict response instead of overwriting silently.

## Import and export

Imports and exports use `AsyncSequence` pipelines with bounded buffers. Format readers and writers cover CSV, TSV, JSON, JSONL or NDJSON, SQL inserts where appropriate, and native formats exposed by a capability report. Parquet is an extension point until a maintained Swift implementation meets packaging and streaming needs.

Mapping and conversion validation occurs on a bounded preview. Execution reports processed, accepted, rejected, and skipped counts plus bounded samples of failures. Resume is offered only when the adapter can establish a stable checkpoint and idempotent behavior.

## CLI contract

The root family is `ed database`, with aliases limited to repository convention. Commands work without a TTY. Human output is concise. `--json` emits one sorted-key JSON document. Page streaming uses `--format ndjson`, writes one record per stdout line, and keeps progress on stderr. Files and stdin are explicit options. Exit codes follow the repository contract: success, request error, operation failure, unavailable capability, and partial success.

Command groups are:

- `connections`: list, get, add, edit, duplicate, rename, remove, test, connect, disconnect, health, import-url, and capabilities.
- `objects`: roots, children, describe, search, refresh, and related.
- `query`: run, explain, cancel, history, save, remove-saved, and list-saved.
- `data`: browse, inspect, insert, update, delete, bulk-update, bulk-delete, import, and export.
- `sql`: execute, transaction, definition, maintenance, sessions, locks, and replication.
- `keyspace`: scan, get, set, create, rename, copy, move, delete, ttl, collection, command, server, cluster, sentinel, and slowlog.
- `mongo`: find, aggregate, schema, insert, replace, update, delete, indexes, validation, change-stream, topology, and server.
- `search`: search, request, document, bulk, mappings, settings, analyze, tasks, templates, pipelines, snapshots, topology, and sql.
- `clickhouse`: query, explain, insert, mutation, parts, partitions, storage, topology, query-log, and running.
- `operations`: list, get, cancel, and history.

Every mutating leaf accepts `--preview`. Applying requires `--confirm-token` or an interactive confirmation when a TTY is present. `--yes` alone cannot bypass a required token. Secret values are read through stdin, a protected file descriptor, Keychain, or environment lookup that stores only the environment variable name in diagnostics.

## MCP contract

`ed database mcp` runs a stdio MCP server using the official Swift SDK. It publishes small, typed tools grouped by intent instead of mirroring every CLI spelling. The main tools are:

- `database_connections`
- `database_capabilities`
- `database_objects`
- `database_describe`
- `database_query`
- `database_browse`
- `database_preview_mutation`
- `database_apply_mutation`
- `database_import`
- `database_export`
- `database_operation`
- `database_cancel_operation`
- `database_keyspace`
- `database_mongo`
- `database_search`
- `database_clickhouse`

Every input requires an explicit connection identifier. Namespace and target fields are structured. Read tools default to 100 records and reject requests over 500. Output carries completeness, truncation, continuation, warnings, and operation identifiers. Mutation preview and apply are separate tools. Tool implementations only translate MCP values into canonical requests and translate shared envelopes back.

The server never returns stored credentials, unbounded schemas, entire large values, or complete datasets. Export returns an operation and a local artifact reference under approved paths, not file contents. Unsupported or permission-limited operations return the same categories and reasons as the CLI and interface.

## Concurrency and lifecycle

Connection attempts, discovery, queries, streams, and exports run in structured tasks owned by operation records. Closing a tab releases its consumer but does not cancel a shared export unless requested. Disconnect cancels session-bound work, closes cursors, releases pools, and preserves a redacted completion record.

The application restores saved tabs as disconnected definitions. It never reconnects to production or mutation-enabled connections at launch without user intent. Stale capability and metadata caches are labeled until refresh succeeds.
