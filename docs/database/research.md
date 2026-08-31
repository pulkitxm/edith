# Open-source product research

Research was performed from clean shallow clones on 2026-08-30 and refreshed for the native workspace pass on 2026-08-31. Exact revisions are recorded so the comparison remains reproducible. Code, layouts, branding, icons, and assets are not copied. SSPL projects are behavior references only.

## Inspected sources

| Product | Repository | Commit | License | Primary value |
| --- | --- | --- | --- | --- |
| pgAdmin 4 | [pgadmin-org/pgadmin4](https://github.com/pgadmin-org/pgadmin4) | `bc58657d3d3ab4209cdadea6d191b632cf1572cc` | PostgreSQL Licence | PostgreSQL administration, plans, monitoring, and ERD |
| DBeaver Community | [dbeaver/dbeaver](https://github.com/dbeaver/dbeaver) | `913a1b5b40a3880b2427abffd3ceccce7eb5aed3` | Apache-2.0 | Cross-database adapters, segmented grid, editing, accessibility |
| Beekeeper Studio | [beekeeper-studio/beekeeper-studio](https://github.com/beekeeper-studio/beekeeper-studio) | `4e3e03e3223b2b71a1af8926d455f533b80af837` | GPL-3.0-or-later for Community | Friendly connections and staged data editing |
| DbGate | [dbgate/dbgate](https://github.com/dbgate/dbgate) | `f5be442d8f7f3ffccb0276b000fa65d042a50581` | GPL-3.0 | Incremental grid, streaming, process isolation, MCP behavior |
| Cove | [emanuele-em/cove](https://github.com/emanuele-em/cove) | `ecf0e56f962257499dd1452a1bc0fcdc6c08c55c` | MIT | Native Swift connection rail, lazy object tree, staged grid, inspector |
| LensDB | [w3debugger/lensdb](https://github.com/w3debugger/lensdb) | `648856a9e3226bf944d96d0f6dc566ccc072cabc` | MIT | Minimal macOS split view, table selection, editable results, appearance |
| Azimutt | [azimuttapp/azimutt](https://github.com/azimuttapp/azimutt) | `3f79c2971a8a3be62ccf6003eb17a7ded7640897` | MIT | Large-schema relationship exploration |
| Harlequin | [tconbeer/harlequin](https://github.com/tconbeer/harlequin) | `0b6067c0b3acb9db135a9c89fc4fbccd84c76d4d` | MIT | Shared interactive and headless query core |
| RedisInsight | [RedisInsight/RedisInsight](https://github.com/RedisInsight/RedisInsight) | `79e1ae9c2851587062ca4db1a75060ee18e28455` | SSPL v1 | Behavior only: Redis workflows, bulk progress, production safety |
| P3X Redis UI | [patrikx3/redis-ui](https://github.com/patrikx3/redis-ui) | `2c478df2039ce677cba19682bd16a9c3bcc405af` | MIT | Redis and Valkey type editors, virtual key browsing, monitoring |
| Redis Commander | [joeferner/redis-commander](https://github.com/joeferner/redis-commander) | `2a222de65ed15832d4d4adfbbce564539b80115f` | MIT | Simpler Redis implementation fallback |
| MongoDB Compass | [mongodb-js/compass](https://github.com/mongodb-js/compass) | `a29ee1bd6ca119bda652f4f26ba532b395a55f09` | SSPL v1 | Behavior only: document UX, pipelines, schema, plans |
| mongo-express | [mongo-express/mongo-express](https://github.com/mongo-express/mongo-express) | `5c64ebbf0282058233a663a27f0e9d12cb494a11` | MIT | Small auditable MongoDB CRUD and command allowlist |
| OpenSearch Dashboards | [opensearch-project/OpenSearch-Dashboards](https://github.com/opensearch-project/OpenSearch-Dashboards) | `685319f7855e9e4c7ec05dd533f67a477c947666` | Apache-2.0 | Saved workspaces, query interruption, observability, accessibility |
| CH-UI | [caioricciuti/ch-ui](https://github.com/caioricciuti/ch-ui) | `7d448a4d2c867de60c648e0cc553c004c138be3f` | Apache-2.0 core, BSL 1.1 Pro | ClickHouse streaming, progress, plans, schemas, query history |

CH-UI Pro features remain outside the implementation reference set. Its BSL paths include scheduling, governance, lineage, query insights, cluster health, alerts, and related licensed modules. Community code and documented product behavior are treated separately.

## Comparison matrix

| Product | Connection flow | Large-data strategy | Editing and safety | Visualization | Long operations | Automation |
| --- | --- | --- | --- | --- | --- | --- |
| pgAdmin 4 | Named groups, SSL, SSH, restrictions, colors | Pages and optional server cursor | Staged keyed edits, DDL preview, confirmation | ERD, schema diff, plans, dashboard | Process watcher with stop and logs | Native tools, no canonical shared contract |
| DBeaver | Driver form, network, SSH, SSL, filters, read-only | 200-row segments and server sort | Staged SQL preview and transaction controls | ERD, plans, dashboards | Unified cancellable jobs | Reusable tasks, separate CLI direction |
| Beekeeper Studio | Simple engine form, URL, TLS, SSH | 100-row remote pages and streaming export | Keyed staged edits, transaction apply, SQL preview | Paid ERD only | Query and export cancellation | No headless database CLI |
| DbGate | Product form, prompt modes, TLS, SSH | 100-row incremental grid and JSONL spool | Change-set SQL confirmation and permissions | ERD, schema compare, charts | Worker progress and abort, uneven driver cancellation | Server packages and MCP behavior |
| Cove | Compact connection rail and native sheets | Server pages in an AppKit table | Staged cells, keyed rows, SQL preview | Schema and relationship inspection | Query cancellation and visible state | GUI only |
| LensDB | Native list with inline connection expansion | Bounded result grid | Staged cells and explicit save | Schema-focused detail | Refresh state only | GUI only |
| Azimutt | Schema import or gateway URL | Selected schema layouts and 100-row query limit | Mainly read-oriented | Best large-schema relationship canvas | Visible cancel is not transport cancellation | Strong schema CLI |
| Harlequin | Adapter profiles and connection strings | Hard caps, extra-row truncation test, Arrow grid | Fail-closed read-only, no data editor | Catalog only | Capability-gated cancel and timeout | First-class `hsql` sharing adapters |
| RedisInsight | Rich Redis, TLS, SSH, cloud, environment | SCAN, virtualization, visible-row metadata | Target typing and batched unlink | Memory, TTL, type, cluster, search | Progress, abort, reports | Deployment API, not data CLI |
| P3X Redis UI | Groups, read-only, Cluster, Sentinel, TLS, SSH | Virtual scroll, worker tree, configurable limits | Diffs, limited undo, matched-key delete | Monitoring, slow log, types, memory, slots | Bounded monitor buffers | Server launcher only |
| Redis Commander | Environment-driven Redis connection | Paged key access | Basic value editing and deletes | Minimal | Request-scoped | Server launcher |
| MongoDB Compass | Advanced auth, TLS, SSH, encryption | 25 to 100 docs, abort, sample and count timeouts | Typed edits and two-stage bulk previews | Schema, data model, plans, indexes, performance | Abortable reads and streams, server bulk not cancellable | GUI launch and import only |
| mongo-express | Server-configured connection | 10-doc offset pages and large-value stubs | Read-only and command allowlist, typed schema delete | Basic stats | Synchronous request weakness | HTTP surface, no complete CLI |
| OpenSearch Dashboards | Data sources, workspaces, auth modes | Sample cap and abort-composed search | Backend RBAC, weak Console confirmations | Logs, metrics, traces, dashboards | Search interceptors and timeout | Server REST, no workspace CLI |
| CH-UI | Direct or tunnel connections | NDJSON batches, 5,000-row chunks, hard caps | Typed drop targets, permissions, audit | Plans, charts, pipelines, models | Query progress, abort, KILL QUERY | Saved-query endpoint, management CLI |

## Adopted patterns

### Connections and workspace

- DBeaver and pgAdmin demonstrate explicit product, TLS, tunnel, namespace, read-only, timeout, and environment context.
- Compass and CH-UI demonstrate stable multi-connection tabs, dirty-state protection, saved queries, and connection-scoped history.
- Cove keeps connection identity narrow and persistent while the object tree and active workspace receive the usable width.
- LensDB uses macOS split-view collapse behavior and keeps the selected database name inside the column body so toolbar controls do not collide.
- Edith adds Keychain-only secrets, a capability report, production protection, and the same shared executor for every surface.

### Lazy navigation

- DBeaver loads navigator children in background and pushes filters to the server.
- Azimutt renders named schema subsets and reveals related objects on demand.
- P3X builds large key trees outside the main interface thread.
- Cove uses compact disclosure rows, native context menus, per-node refresh, and create or drop actions scoped to the selected tree path.
- Database uses paged metadata roots and children, searchable subsets, relationship-neighbor reveal, and explicit stale cache state.

### Large data

- DBeaver separates visible page size, driver fetch size, and server limits. It only sorts on the client when the set is complete.
- DbGate spools query rows to JSONL and ingests bounded batches.
- Harlequin probes one extra row to describe truncation accurately and fails closed when cancellation or read-only guarantees are unavailable.
- Redis tools use SCAN and virtual rows instead of KEYS.
- Compass cancels stale schema and aggregation previews and gives counts a time budget.
- CH-UI streams NDJSON with row, byte, single-value, and total-result limits.

Database therefore combines a small server page, explicit completeness, stable continuations, bounded decode buffers, native virtual rows, server filters and sorts, streamed export, and separate large-value requests.

### Editing and destructive work

- Beekeeper and DBeaver require safe row identity, stage changes, expose diffs, and preview generated SQL before an atomic apply.
- Cove keeps ordinary edits in the grid, presents one review action only while changes are pending, and puts page controls in a quiet footer.
- LensDB highlights only changed cells and new rows, which keeps the unmodified dataset visually dominant.
- RedisInsight asks for a database target on production mutations and performs bulk deletion as SCAN plus bounded pipelines.
- Compass previews affected count and representative documents before bulk mutation.
- mongo-express uses server-side command allowlists and configuration-enforced read-only behavior.
- CH-UI protects system databases and requires exact target names for drops.

Database places these controls in the canonical executor. Every mutation has a structured preview and strong operations require a signed, short-lived token. Interface hiding never substitutes for server-side policy.

### Plans and visualizations

- pgAdmin renders one PostgreSQL plan as graphical, table, and raw forms.
- DBeaver normalizes driver-specific plans and provides accessible grid context.
- Azimutt keeps relationship diagrams useful by starting with selected objects.
- Redis tools focus on type, TTL, memory, namespace, and topology distributions.
- Compass combines bounded schema sampling, relationship inference, plans, and index usage.
- OpenSearch Dashboards couples saved searches with accessible analytical charts.
- CH-UI exposes ClickHouse plan trees, process progress, schema keys, pipelines, and models.

Database normalizes plan nodes where meaningful while retaining raw product output. Every chart has a tabular alternative. Diagrams have subset selection, search, progressive layout, and cancellation.

### Operations and cancellation

- pgAdmin gives background work durable visible state and logs.
- DBeaver propagates progress and cancellation through jobs and statements.
- DbGate isolates database work in processes but exposes incomplete cancellation paths that must not be repeated.
- Compass shows that server bulk mutation may become non-cancellable after dispatch.
- CH-UI assigns query IDs, polls process state, aborts transport, and issues KILL QUERY.

Database models queued, running, cancelling, succeeded, failed, cancelled, and partial states. An adapter reports the real cancellation level and the interface explains when a server has already accepted irreversible work.

### CLI and MCP

- Harlequin is the strongest reference because interactive and headless clients share adapters, profiles, limits, serialization, error behavior, read-only enforcement, and cancellation.
- DbGate proves bounded MCP reads and server-side permissions are valuable, but premium-gated writes are not a suitable contract.
- None of the inspected products offers complete UI, CLI, and MCP parity.

Database defines typed shared requests first. CLI and MCP only parse, render, and transport them. MCP pages are smaller than interface pages and never inject an entire dataset into context.

## Weaknesses explicitly avoided

| Weakness | Products exhibiting it | Database response |
| --- | --- | --- |
| Heavy platform architecture and inconsistent plugin capabilities | DBeaver, OpenSearch Dashboards | Small Swift protocols and explicit capability reasons |
| Desktop density without responsive reorganization | pgAdmin, DBeaver, Beekeeper | Container-width modes, focused panels, and overflow actions |
| Offset pagination for deep data | Compass, mongo-express | Cursor, keyset, PIT, and `search_after` continuations |
| Full or large result materialization | mongo-express CSV, Harlequin cap, CH-UI high cap | Bounded pages and streaming destinations |
| Sample-capped grid presented like complete data | OpenSearch Dashboards | Persistent partial, sampled, and truncation labels |
| Cosmetic cancellation | Azimutt, parts of DbGate and Console | Transport and server cancellation with truthful capability state |
| Weak bulk confirmation or unsafe default | P3X FLUSHDB path, mongo-express document default, Dev Tools | Executor-enforced preview and target-bound token |
| Credentials in configuration | P3X | Keychain references only |
| Product behavior hidden behind protocol compatibility | General cross-database tools | Separate identity, capability, implementation, and real-product tests |
| Inaccessible virtual rows or icon controls | Several web tools | Keyboard grid contract, focus restoration, names, announcements, and table alternatives |
| GUI-only automation | Most inspected tools | Complete `ed database` and MCP adapters over shared execution |

## Driver and package decisions

| Component | Selection | Reason |
| --- | --- | --- |
| PostgreSQL | PostgresNIO | Maintained pure Swift, streaming, TLS, cancellation, and pooling ecosystem |
| MySQL and MariaDB | MySQLNIO | Maintained native protocol and parameter binding with shared pooling added above it |
| SQLite | GRDB | Maintained SQLite integration, transactions, typed values, and robust persistence primitives |
| Redis and Valkey | RediStack | Maintained SwiftNIO RESP client with pipelining and explicit command control |
| MongoDB | MongoKitten | Maintained pure Swift driver with BSON, cursors, aggregation, sessions, transactions, and change streams |
| Elasticsearch and OpenSearch | URLSession | Official HTTP APIs, incremental bytes, explicit product request builders, no extra client abstraction |
| ClickHouse | URLSession HTTP | Native streamed formats, query IDs, progress, and product APIs without an immature driver dependency |
| MCP | Official Swift MCP SDK | Typed server, stdio transport, cancellation, progress, and current protocol support |

All new packages are pinned through Swift Package Manager resolution and pass dependency, license, security, signing, and bundle checks. Convenience HTTP APIs that buffer the whole response are prohibited in large-result paths.
