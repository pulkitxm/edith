# Database verification strategy

Database verification combines deterministic unit and contract tests, opt-in real-product integration, rendered interface journeys, performance measurements, and recorded TUF results. No adapter is claimed from protocol compatibility alone.

## Test layers

| Layer | Purpose | Runs in required CI |
| --- | --- | --- |
| Model tests | Values, identifiers, continuations, capability reports, errors, redaction | Yes |
| Policy tests | Read-only, production, preview, token binding, expiry, single use | Yes |
| Adapter contract tests | Paging, identity, cancellation, partial failures, capability consistency | Yes, with deterministic fakes |
| Product parser tests | Version, distribution, topology, metadata, type and plan fixtures | Yes |
| Persistence tests | SQLite migrations, concurrent writers, Keychain abstraction, recovery | Yes with in-memory secret store |
| CLI tests | Real parser execution, stdout, stderr, JSON, NDJSON, exit codes, stdin | Yes |
| MCP tests | Tool schemas, bounds, parity, cancellation, structured errors, output isolation | Yes |
| UI model tests | State transitions, stale request rejection, bounded adoption, focus targets | Yes |
| Render and accessibility tests | Wide, narrow, themes, text scale, states, labels, keyboard actions | Yes |
| Real-product integration | Live behavior through Mac loopback and TUF Docker | Recorded locally, opt-in harness |
| Million-record performance | Resource bounds, latency, throughput, cancellation, recovery | Recorded locally, opt-in harness |

Required hosted CI does not depend on a private TUF machine. It runs all deterministic layers and verifies that integration manifests, seed scripts, expected capability fixtures, and result schemas remain valid.

## Deterministic seams

Tests inject:

- Adapter registry and family sessions
- Clock, identifiers, random source, and token signer
- Keychain store and metadata database location
- Tunnel coordinator and port allocator
- HTTP transport and streaming byte source
- Product driver factories
- Operation history and spool directory
- Memory budget and page-limit configuration

Fakes must model delay, cancellation, partial pages, continuation expiry, permission loss, network interruption, server errors, huge values, empty databases, large metadata trees, and non-cancellable accepted mutations.

## Contract invariants

Every adapter test suite proves:

1. Product identity is established before product-specific capabilities are advertised.
2. A page never exceeds requested or hard record, field, byte, and value-preview limits.
3. A continuation cannot be used with a different connection, target, projection, filter, sort, or query.
4. An incomplete result is labeled and never client-sorted or client-filtered as if complete.
5. Missing and null remain distinct.
6. Stable record identity is present only when the adapter can prove it.
7. Read-only mode rejects every mutation and unsafe arbitrary command path.
8. Preview and apply normalize to the same effect digest.
9. Expired, changed, consumed, or cross-connection confirmation tokens fail.
10. Cancellation releases cursors, leases, buffers, and session work where supported.
11. Timeout and cancellation are distinct structured errors.
12. Network failure does not trigger a mutation retry.
13. Secret patterns never appear in results, errors, history, logs, or tool output.
14. One failed session does not change another session's state.
15. Operation history stays bounded and excludes result payloads.

## Real-product matrix

Task-owned containers use explicit names, labels, volumes, networks, published ports, authentication, and health checks. TUF ports are forwarded to matching Mac loopback ports through Edith Machines.

| Product | Initial version line | Container | TUF port | Mac port | Dataset |
| --- | --- | --- | ---: | ---: | --- |
| PostgreSQL | 17 | `edith-db-postgres` | 55432 | 55432 | `events` near 1,000,000 rows plus relational/type fixtures |
| MySQL | 8.4 | `edith-db-mysql` | 53306 | 53306 | `events` near 1,000,000 rows plus relational/type fixtures |
| MariaDB | 11.8 | `edith-db-mariadb` | 53307 | 53307 | `events` near 1,000,000 rows plus relational/type fixtures |
| SQLite | macOS runtime | Local fixture file | Not applicable | Not applicable | `events` near 1,000,000 rows plus relational/type fixtures |
| Redis | 8 | `edith-db-redis` | 56379 | 56379 | Near 1,000,000 keys across native types |
| Valkey | 8 | `edith-db-valkey` | 56380 | 56380 | Near 1,000,000 keys across native types |
| MongoDB | 8 | `edith-db-mongodb` | 57017 | 57017 | `events` near 1,000,000 diverse documents |
| Elasticsearch | Current supported stable | `edith-db-elasticsearch` | 59200 | 59200 | `events` near 1,000,000 mapped documents |
| OpenSearch | Current supported stable | `edith-db-opensearch` | 59201 | 59201 | `events` near 1,000,000 mapped documents |
| ClickHouse | Current supported stable | `edith-db-clickhouse` | 58123, 59000 | 58123, 59000 | MergeTree fixtures with at least 1,000,000 rows |

The integration manifest records the exact image tag and immutable image ID used by a result. Product versions are detected from the running server and compared with the manifest. Credentials are generated test values supplied outside version control. TLS-off results are labeled and do not satisfy the separate TLS test case.

## Container ownership

Every resource carries `com.edith.database-test=true` plus an owner label. SQL, key-value, document, search, and analytical tasks use separate networks and unique volumes. Scripts address exact names and reject resources whose ownership labels do not match.

No script runs Docker prune, stops an unknown container, removes an unknown volume, or deletes an existing forward. Cleanup prints and validates its exact resource list before removal. Test resources remain available through review unless explicitly cleaned up.

Readiness is a product query, not container process state. Each service waits for authenticated ping or a minimal query and reports the detected version.

## Seed data

Seeds are versioned manifests plus idempotent product scripts. They use a fixed random seed and record start, finish, count, storage, and index timing.

### Relational products

Each product contains:

- A near-million-row `events` table with integer identity, UUID-like stable value, nullable values, booleans, integer widths, decimal, floating point, dates, times, timestamps, Unicode text, long text, binary, JSON, skewed and high-cardinality dimensions, and indexed and unindexed fields.
- Parent and child tables with foreign keys.
- A composite-key table.
- A table without a primary key.
- Unique, check, and product-supported generated columns.
- Views, triggers, routines, and a materialized view or documented unsupported capability.
- PostgreSQL arrays, enums, partitions, ranges, JSONB, and identity fixtures.
- MySQL and MariaDB product-specific generated, enum, JSON, engine, and plan fixtures.
- SQLite strict, WITHOUT ROWID, generated, JSON, trigger, and view fixtures when supported.

PostgreSQL uses `generate_series`. MySQL and MariaDB use bounded server-side recursive or digits-based generation inside transactions. SQLite uses a recursive source and prepared transaction batches. The seed process never creates one million client objects in memory.

### Redis and Valkey

Near one million keys are distributed over strings, hashes, lists, sets, sorted sets, streams, TTL and persistent keys, small and large values, binary values, and Unicode names. Module-backed types are separate optional fixtures after capability detection. Cluster slot tests use a separate explicitly declared deployment.

Generation writes bounded RESP batches through `redis-cli --pipe`. Verification uses DBSIZE, sampled TYPE and TTL commands, and SCAN traversal. KEYS is prohibited in scripts and tests.

### MongoDB

The main collection contains nested objects, arrays, missing fields, nulls, ObjectIds, dates, Decimal128, binary, GeoJSON, Unicode, high and low cardinality, skew, and bounded large documents. Fixtures include compound, unique, TTL, geo, and text or wildcard indexes plus validation.

Generation runs bounded bulk inserts on TUF. Verification records exact count, sampled BSON types, index definitions, storage statistics, and explain output for indexed and unindexed predicates.

### Elasticsearch and OpenSearch

Separate product indices use text, keyword, numeric, date, boolean, nested, array, geo, missing, high and low cardinality, and bounded large source fields. Multiple shards exercise allocation without overwhelming a single-node test.

Generation sends bounded NDJSON `_bulk` requests. Verification checks document count, mappings, shards, storage, PIT availability, `search_after`, aggregations, highlighting, task behavior, and product-specific headers and APIs.

### ClickHouse

MergeTree fixtures include partitions, order and primary keys, LowCardinality, Nullable, Array, Tuple, Map, Decimal, Date, DateTime, long strings, materialized columns, a materialized view, projection, data-skipping index, and TTL where safe.

Seeds use `INSERT SELECT` from `numbers(1000000)`. Verification checks count, partitions, parts, storage, projection and index definitions, plan output, query log, and materialized-view flow.

## Adapter journey

Every real product run covers:

- Saved definition and secret resolution
- Direct connection test through the Mac loopback forward
- Product, version, topology, permission, and capability discovery
- Lazy roots, children, description, refresh, and search
- Bounded browse, projection, typed filter, stable sort, and continuation
- Query or command execution with structured result
- Insert or create, single edit, and single delete
- Guarded bulk preview, token apply, and partial-failure handling
- Import and streamed export
- Explain or documented unsupported behavior
- Cancellation and timeout
- Read-only rejection and a limited-permission account
- Disconnect, reconnect, and unrelated-session isolation
- CLI human, JSON, and NDJSON output
- MCP bounded tool call, continuation, mutation preview, and cancellation
- Rendered interface flow and state transitions

Unsupported server operations must be absent or disabled with the runtime capability reason, then covered by a negative test.

## Port-forward interruption

Representative PostgreSQL, Redis or Valkey, MongoDB, search, and ClickHouse runs use this sequence:

1. Connect from the Mac loopback port.
2. Start a bounded slow or streaming operation with a known operation ID.
3. Stop only the task-owned Edith forward.
4. Observe a structured network or tunnel error in CLI, interface, and MCP.
5. Verify the interface remains responsive and another connection still succeeds.
6. Restore the forward.
7. Reconnect and execute a fresh read.
8. Verify the interrupted operation did not silently retry.
9. For a mutation, verify server state before deciding whether a deliberate retry is safe.

Forward ownership, stop time, error time, reconnect time, and final result are recorded.

## Performance measurements

Each million-record run records server and client context plus:

- Connection and capability discovery time
- Metadata first-root time
- First visible interface page
- First CLI record
- First MCP page
- Peak Mac resident memory for a normal page, scroll, export, and visualization
- Grid frame responsiveness during incremental loading
- Indexed and representative unindexed filter latency
- Stable pagination traversal behavior
- Cancellation latency at transport and server levels
- Bulk preview and execution duration
- Export throughput and bounded buffer high-water mark
- Tunnel interruption and reconnect duration

Network, server load, storage, caches, product configuration, and machine model are recorded, so latency is observational rather than a universal guarantee. The pass condition is bounded Mac memory and continued interface responsiveness independent of total dataset size.

## UI inspection matrix

Rendered journeys cover light and dark themes at widths 1,440, 1,024, 760, and 560 points, plus short height and large text. They include initial setup, empty data, loading, partial, stale, permission-limited, disconnected, read-only, production preview, operation progress, error, cancellation, and success.

Inspection verifies panel resize and persistence, focused mode, toolbar overflow, contained grid scrolling, pinned identity, column selection, record detail, narrow editing, dialog action visibility, focus restoration, keyboard tree and grid navigation, announcements, non-color status, reduced motion, and chart table alternatives.

## Result records

Integration and performance runs write redacted JSON result documents under an ignored artifacts directory. Approved summaries with no credentials, private endpoints, or unrelated machine data are committed under `docs/database/results/`. Each summary identifies source commit, adapter, product version, image ID, seed version, counts, commands, measured context, pass or failure, limitation, and evidence artifact.

A claim is complete only when its exact result exists and the corresponding automated contract is green.
