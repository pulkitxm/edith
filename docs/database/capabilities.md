# Database capability matrix

This matrix is the product contract. Runtime reports refine it by version, topology, module, plugin, permission, and connection policy.

Status values are:

- **Shared required**: implemented through the common command layer for every applicable adapter.
- **Family required**: implemented for every supported product in the named family.
- **Product required**: implemented and tested for the named product.
- **Planned extension**: represented by contracts but not claimed as working.
- **Unsupported**: deliberately unavailable for the documented reason.

## Shared platform

| Capability | Status | Scope and rule |
| --- | --- | --- |
| Saved connections | Shared required | Create, edit, duplicate, rename, delete, group, tag, color, favorite, search, and recent use |
| Concurrent connections | Shared required | Isolated sessions with independent lifecycle, health, errors, and cancellation |
| Connection test | Shared required | Cancellable pre-save test with product identity and safe error |
| Health and reconnect | Shared required | Explicit connect, disconnect, reconnect, timeout, and stale state |
| URL import | Shared required | Product-aware parsing that never prints embedded secrets |
| Structured fields | Shared required | Host or path, namespace, user, timeouts, pool, and product options |
| Secure credentials | Shared required | Keychain-backed password, token, key, and certificate references |
| TLS verification | Shared required | Verify by default for network products, explicit insecure warning |
| Client certificates | Family required | Products and drivers that support mutual TLS |
| Edith machine tunnel | Shared required | Loopback forward, owned lifecycle, collision checks, and reconnect |
| Read-only mode | Shared required | Fail closed when the adapter cannot enforce the requested guarantee |
| Production protection | Shared required | Persistent label and mandatory mutation preview |
| Capability report | Shared required | Product, version, topology, features, limits, permissions, and reasons |
| Lazy object discovery | Shared required | Paged roots and children, search, refresh, favorites, and breadcrumbs |
| Bounded browsing | Shared required | Server filters, sorts, projection, stable continuation, and limits |
| Rich values | Shared required | Null, missing, binary, numeric precision, temporal, structured, and typed text |
| Large value inspection | Shared required | Metadata and bounded preview before explicit chunked loading |
| Insert or create | Shared required | Native model operation with typed values |
| Single-record mutation | Shared required | Stable identity or deliberate predicate required |
| Bulk mutation | Shared required | Preview, bounded batches or server task, partial failures, and cancellation |
| Destructive confirmation | Shared required | Signed, expiring, single-use token bound to the normalized effect |
| Import | Shared required | Streaming CSV, TSV, JSON, and JSONL where model-compatible |
| Export | Shared required | Streaming CSV, TSV, JSON, JSONL, and native formats where exposed |
| Parquet | Planned extension | No selected maintained Swift streaming dependency satisfies packaging needs |
| Query or command history | Shared required | Redacted, bounded, searchable, and connection-scoped |
| Saved queries | Shared required | Named, tagged, model-aware, and connection or family scoped |
| Long-running operations | Shared required | Stable IDs, progress, timeout, cancellation, partial state, and history |
| Automatic mutation retry | Unsupported | Non-idempotent work is never silently retried |
| Exact counts by default | Unsupported | Can require an unbounded scan and block first-page delivery |
| Unbounded fetch | Unsupported | Violates client memory and context limits |
| UI, CLI, MCP parity | Shared required | Same requests, validation, capabilities, safety, envelopes, and errors |
| Local diagnostics | Shared required | Explicit export only, with secret redaction and no telemetry |

## Relational family

| Capability | Status | Product notes |
| --- | --- | --- |
| Catalog and schema tree | Family required | Product-native catalogs, schemas, tables, views, and routines |
| Column and type metadata | Family required | Defaults, generated state, nullability, product type, and size |
| Constraints and indexes | Family required | Primary, foreign, unique, check, and product-specific details |
| Server-side filters and sorts | Family required | Parameter values remain separate from generated SQL |
| Keyset pagination | Family required | Used when a stable unique order exists |
| Offset pagination | Family required | Used only for bounded or explicitly requested browsing |
| Stable row identity | Family required | Primary or safe unique key; absence disables implicit row editing |
| Inline and form edits | Family required | Staged diff, reset, generated SQL preview, and atomic apply when supported |
| Multi-row paste | Family required | Parsed and validated into bounded parameterized batches |
| Transactions | Family required | Capability reports isolation, savepoints, and DDL behavior |
| SQL editor | Family required | Tabs, selection or statement execution, parameters, timing, and result sets |
| Dialect highlighting | Family required | Keywords, strings, identifiers, parameters, and comments in input text |
| Schema completion | Family required | Bounded lazy metadata cache with explicit refresh |
| Formatting | Family required | Dialect-aware tokenizer and indentation for supported statements |
| Explain | Family required | Raw and normalized tree, with analyze warnings where supported |
| ER and dependency diagrams | Family required | Selected subset, neighbor reveal, search, grouping, and progressive layout |
| Roles and permissions | Family required | Inspect where permitted, mutate only through product capability |
| Sessions and running queries | Family required | Inspect and cancel or terminate with strong confirmation |
| Maintenance | Family required | Product-native analyze, vacuum, optimize, or equivalent when supported |
| Backup and restore | Planned extension | Requires external tool lifecycle, file access, version matching, and deeper recovery UX |

## PostgreSQL

| Capability | Status | Gate |
| --- | --- | --- |
| Databases and schemas | Product required | Catalog visibility and CONNECT or USAGE privileges |
| Partitioned and foreign tables | Product required | Server version and catalog visibility |
| Materialized views | Product required | Owner or maintenance privilege for refresh |
| Extensions | Product required | Catalog visibility, creation capability reported separately |
| Enums, domains, arrays, ranges, JSONB | Product required | Native type mapping with typed fallback |
| Generated and identity columns | Product required | Server version |
| Index methods and details | Product required | Access method and catalog visibility |
| Row-level security policies | Product required | Catalog visibility and table privilege |
| Roles and grants | Product required | Current-role visibility and administration rights |
| Publications and subscriptions | Product required | Server version and replication catalog permissions |
| Replication slots | Product required | Replication permissions |
| Activity, locks, and cancellation | Product required | Statistics visibility and backend ownership or elevated permission |
| Query plans | Product required | EXPLAIN, with explicit ANALYZE confirmation for modifying statements |
| Vacuum and analyze state | Product required | Statistics visibility |
| Reliable bloat indicator | Planned extension | Estimates vary by extension, version, and workload and need explicit confidence |
| Sequences and identity state | Product required | Sequence privileges |
| Server configuration | Product required | Inspect broadly, edit only when context and permissions make it safe |
| Large objects | Planned extension | Requires separate streaming and lifecycle UX |
| Listen and notify | Planned extension | Unbounded subscription semantics need a dedicated bounded monitor |

## MySQL and MariaDB

| Capability | Status | Gate |
| --- | --- | --- |
| Separate product detection | Product required | Version and product variables, never protocol assumption |
| Databases, tables, views, routines, triggers | Product required | Information Schema and product catalogs |
| Native types and generated columns | Product required | Product and version-specific mapping |
| InnoDB transactions and locks | Product required | Engine and permission detection |
| Explain tree or JSON | Product required | Product-specific EXPLAIN format support |
| Process list and cancellation | Product required | PROCESS privilege and thread ownership |
| Users and grants inspection | Product required | Permission-limited |
| Replication inspection | Product required | Product-specific status and privilege |
| Table optimization and analysis | Product required | Engine and privilege gates |
| MySQL and MariaDB administration parity | Unsupported | Their syntax, catalogs, replication, and optimizer outputs differ |

## SQLite

| Capability | Status | Gate |
| --- | --- | --- |
| Local file and in-memory connection | Product required | File bookmark or explicit path |
| Tables, views, triggers, indexes | Product required | `sqlite_schema` and pragma functions |
| Rowid identity | Product required | Only when table semantics permit it |
| WITHOUT ROWID and strict tables | Product required | Runtime version |
| Transactions and savepoints | Product required | Native SQLite behavior |
| Query plans | Product required | EXPLAIN and EXPLAIN QUERY PLAN |
| Integrity and optimize actions | Product required | Explicit maintenance operation |
| Network TLS, users, roles, replication | Unsupported | SQLite is an embedded database and has no such server concepts |

## Redis and Valkey

| Capability | Status | Gate |
| --- | --- | --- |
| Separate Redis and Valkey detection | Product required | INFO, command metadata, version, and distribution |
| Standalone | Family required | Native RESP session |
| Sentinel | Family required | Discovered masters, replicas, and failover state |
| Cluster | Family required | Slots, nodes, redirection, and topology |
| SCAN browsing | Family required | Incremental, cancellable, partial, pattern and type filters |
| KEYS browsing | Unsupported | Can block large or unknown keyspaces |
| Strings and binary strings | Family required | Bounded preview and explicit full load |
| Hashes, lists, sets, sorted sets | Family required | Cursor or range reads and native mutations |
| Streams | Family required | Ranged reads, append, groups, consumers, pending, and acknowledge |
| TTL, rename, copy, move | Family required | Command and deployment capability |
| Guarded bulk delete | Family required | SCAN plus bounded UNLINK or DEL batches |
| Transactions | Family required | MULTI, EXEC, DISCARD, and WATCH behavior reported |
| Memory, clients, command stats, slow log | Family required | Permission and configuration gates |
| Replication, cluster, Sentinel, ACL | Family required | Topology and permission gates |
| Bounded Pub/Sub inspection | Family required | Explicit subscription, rate limit, stop, and retention cap |
| HyperLogLog, bitmap, geo | Family required | Native command capability |
| RedisJSON or Valkey JSON | Product required | Only when compatible module or built-in commands are detected |
| Search modules | Product required | Only when compatible module commands are detected |
| Arbitrary unknown modules | Planned extension | Requires registered type and command schemas for safe editing |

## MongoDB

| Capability | Status | Gate |
| --- | --- | --- |
| Standalone, replica set, sharded cluster | Product required | hello response, topology, and wire version |
| Authentication database and mechanisms | Product required | Driver and server mechanism support |
| Databases, collections, views, stats | Product required | Permission-limited metadata |
| Bounded find and projection | Product required | Cursor, stable sort, limit, max time, collation, and hint |
| Extended JSON views | Product required | Tree, source, form, and typed BSON preservation |
| Insert, replace, update, delete | Product required | Single and guarded bulk operations |
| Aggregation pipeline | Product required | Ordered stages, enable state, results, and explain |
| Index management | Product required | Compound, unique, sparse, partial, text, TTL, geo, and wildcard when available |
| Schema inference | Product required | Clearly labeled bounded sample, field presence, and type distributions |
| Validation rules | Product required | Inspect and edit with collection capability |
| Sessions and transactions | Product required | Deployment topology and wire-version gate |
| Change streams | Product required | Explicit start and stop, backpressure, and bounded retention |
| Replica and shard topology | Product required | Permission and deployment gate |
| Current operations, status, profiling | Product required | Permission gate and explicit profiling mutation |
| GridFS | Planned extension | File transfer needs a distinct streaming and preview experience |
| Complete inferred schema | Unsupported | A bounded sample cannot prove the schema of every document |

## Elasticsearch and OpenSearch

| Capability | Status | Gate |
| --- | --- | --- |
| Separate product and distribution detection | Product required | Headers, root response, version, build, plugins, and feature probes |
| Clusters, nodes, health | Family required | Cluster monitor permissions |
| Indices, aliases, streams, templates | Family required | Product version and index permissions |
| Mappings, settings, shards, allocation | Family required | Product version and permission gates |
| Query DSL and full-text search | Family required | Bounded source and field selection |
| PIT plus search_after | Family required | Preferred deep interactive continuation when supported |
| Scroll | Family required | Export and batch only, not normal browsing |
| Deep offset browsing | Unsupported | Cost grows with offset and is unsafe at scale |
| Aggregations and charts | Family required | Bounded buckets with truncation labels |
| Document and bulk mutation | Family required | Concurrency metadata and item-level failures |
| Delete or update by query | Family required | Preview, asynchronous task when supported, progress, and cancellation |
| Reindex and task monitoring | Family required | Task API capability |
| Index lifecycle actions | Family required | Create, close, open, rollover, refresh, flush, and guarded delete |
| Analyzer testing | Family required | Product API capability |
| Snapshots and repositories | Family required | Inspect by default, mutation permission-gated |
| Ingest pipelines and search templates | Family required | Product and permission gates |
| Elasticsearch SQL | Product required | Availability and license response |
| OpenSearch SQL and PPL | Product required | Plugin detection and permission |
| Cross-product feature assumption | Unsupported | API, licensing, plugins, and security behavior diverge |

## ClickHouse

| Capability | Status | Gate |
| --- | --- | --- |
| Databases, tables, views, dictionaries | Product required | System table visibility |
| Engines and MergeTree configuration | Product required | Engine metadata and create query |
| Columns, types, codecs, keys, indexes | Product required | System metadata and version |
| Parts, partitions, replicas, clusters | Product required | System table visibility and topology |
| Streaming query and formats | Product required | HTTP streamed response and bounded decode |
| Explain syntax, plan, pipeline, indexes | Product required | Version-specific EXPLAIN support |
| Query log and running queries | Product required | System table visibility |
| Query cancellation | Product required | Query identifier and KILL QUERY permission |
| Insert and batch import | Product required | Streamed supported formats |
| Storage and data-flow visualization | Product required | Bounded system-table queries |
| ALTER UPDATE and ALTER DELETE | Product required | Strong preview, asynchronous mutation ID, state, and failures |
| Lightweight delete | Product required | Version, table engine, and setting gate |
| Partition and optimize operations | Product required | Strong warning and permission gate |
| Transactional row editor | Unsupported | ClickHouse mutations are analytical and often asynchronous, not OLTP row commits |
