# Database experience specification

## Primary journeys

### First connection

1. The empty state explains supported products, local versus tunneled access, and secure credential storage.
2. The user chooses a product. The form shows only product-relevant fields and offers URL import.
3. Authentication, TLS, tunnel, namespace, timeouts, pool, read-only, and environment settings are progressive sections.
4. Test Connection reports the detected product, version, topology, latency, TLS state, effective namespace, permission summary, and limitations.
5. Save creates the non-secret metadata transaction and Keychain items. Open enters the matching model workspace.

A connection attempt is cancellable. A failed test preserves form values without retaining a new secret beyond the active form. Production is a text-and-icon label, not only a color.

### Resume work

The connection rail presents favorites, recent connections, groups, tags, health, active sessions, read-only state, and environment. Search matches names, tags, product, endpoint, and namespace without inspecting secrets. Several sessions can be connected simultaneously. Tabs keep a stable connection identifier and visibly label stale or disconnected context.

At launch, tabs restore disconnected. The user reconnects deliberately, especially for production connections.

### Browse and edit

The object explorer fetches only roots and expanded children. Selecting a data object opens a bounded first page. Filter, sort, and projection controls issue a new server request. The grid states whether results are complete, sampled, estimated, truncated, or stale.

Selecting a row, key, document, or search hit opens a detail inspector. Edits are staged locally, preserving original and proposed values. Apply opens the canonical mutation preview. A successful apply returns changed values when the product supports them and refreshes only affected scope.

For a relation without a stable key, implicit row editing is disabled. The user can create an explicit predicate operation with a stronger preview.

### Query and command

Each editor tab binds a connection and namespace. Its tab, toolbar, gutter, and execute control repeat the connection context. Changing the connection is explicit and never automatic after a disconnect.

The editor executes the current statement, selection, or script. It supports parameters, bounded results, messages, timing, affected rows, cancellation, history, saved queries, and export. SQL tabs add formatting, schema completion, transactions, and explain. Native tabs use Redis commands, MongoDB query and pipeline documents, search DSL, or ClickHouse SQL and formats.

Explain Analyze and any command that can mutate display a warning before execution. Error locations select the corresponding editor range when the product returns usable location data.

### Destructive operation

The preview sheet identifies:

- Connection and environment
- Product and version
- Database, schema, logical database, collection, index, or cluster
- Target object
- Selection or predicate
- Generated statement or request
- Exact or estimated effect and confidence
- Transaction and rollback behavior
- Synchronous or asynchronous behavior
- Product warnings and required confirmation level

The primary action names the effect, such as Delete 24 documents. Unrestricted deletes, truncation, drops, privilege changes, session termination, search delete-by-query, and ClickHouse mutations require retyping the target identity. The interface submits the shared confirmation token and cannot weaken the executor policy.

### Long-running operation

Running work appears in the tab and operation center. Each row shows state, connection, target, elapsed time, determinate or indeterminate progress, processed counts, warnings, and Cancel when supported. Closing the presenting tab does not lose operation visibility. Cancellation reports whether the server accepted cancellation and whether partial work may remain.

Completed entries retain metadata and redacted outcomes, not complete result payloads. Retry appears only for safe idempotent operations or creates a fresh preview.

## Model workspaces

### Relational

The explorer groups catalogs, schemas, relations, routines, types, roles, sessions, and product-native administration. Relation tabs combine Data, Structure, Constraints, Indexes, Relationships, Definition, Statistics, and product-specific pages.

The SQL workspace includes editor, result tabs, messages, plan, transaction state, and history. Staged table edits show changed cells, row-level diffs, generated parameterized statements, and commit or rollback controls.

ER diagrams start with a chosen table or selected subset, reveal adjacent relationships on demand, support search and grouping, and never render an entire large schema by default.

### Keyspace

The keyspace explorer uses SCAN cursor pages with pattern and detected-type filters. It shows partial-result state throughout a scan. Key rows present type, TTL, size when available, and a bounded value summary.

The inspector uses native editors for strings, hashes, lists, sets, sorted sets, streams, geo data, bitmaps, HyperLogLog, and detected module types. Collection views fetch bounded ranges or cursor pages. Bulk delete scans and unlinks in bounded batches with live progress.

Monitoring covers memory, clients, command rates, slow log, replication, Sentinel, Cluster slots, and ACL visibility. Pub/Sub is an explicit bounded live operation with stop and retention limits.

### Document

The collection workspace provides query document, projection, sort, collation, hint, limit, and maximum execution time controls. Documents switch among tree, Extended JSON source, and form views while retaining BSON types, missing fields, and explicit nulls.

Aggregation pipelines are ordered stage cards that can be edited, disabled, reordered, explained, and run. Schema analysis is a bounded sample with coverage, sample size, field presence, type distributions, and index context.

Change streams require an explicit start, show resume context, apply backpressure, retain a bounded event window, and stop on demand.

### Search

The index workspace combines Query DSL, result documents, mapping, settings, aliases, shards, storage, tasks, templates, pipelines, and product-specific SQL or PPL. Results use a point-in-time and stable `search_after` continuation when available.

Aggregation responses can become tables, bars, lines, areas, or distributions only when shape and bucket bounds are suitable. Every chart has an accessible table and states sampling or truncation.

Bulk, reindex, update-by-query, and delete-by-query operations show task state and item-level partial failures. Elasticsearch and OpenSearch badges and capability reasons make product differences explicit.

### Analytical

The ClickHouse workspace centers on SQL, streamed results, table engines, partitions, parts, keys, codecs, projections, indexes, storage, query log, running queries, and cluster state.

Partition, part, and column size views reveal a selected bounded subset. Materialized-view data flow starts from a selected source or target. ALTER mutations show their asynchronous identifier, affected parts, progress, latest failure, and cancellation availability. They never appear as synchronous row edits.

## Layout behavior

The workbench responds to its application container rather than the screen size.

| Available width | Layout |
| ---: | --- |
| 1,280 points and above | Connection rail, object explorer, workspace, and optional inspector |
| 960 to 1,279 points | Combined collapsible navigation, workspace, and collapsible inspector |
| 680 to 959 points | Workspace plus one resizable navigation or inspector panel |
| Below 680 points | Single focused surface with navigation and inspector as sheets or tabs |

Panel sizes and collapsed state persist per workspace within sensible minimum and maximum bounds. At short heights, editor and results use a draggable split with quick focus actions. Toolbar priorities determine which actions enter the overflow menu.

The grid owns horizontal scrolling. Identifier columns can remain pinned. Column selection, record detail, editing, filter, and sort remain reachable at every width. Dialog content scrolls while action controls remain visible. Long names truncate with accessible full labels and tooltips.

Charts reflow legends, reduce visible series through explicit grouping, and offer focused detail. Diagrams show a selected neighborhood with zoom, search, and progressive layout. No visualization mounts thousands of nodes.

## Grid interaction

The native grid uses a bounded in-memory window and reuses row and cell views. It supports:

- Arrow-key cell navigation, page movement, Home and End within the loaded page, and explicit next-page commands.
- Shift range selection and Command additive selection without fetching unloaded records.
- Accessible row and column context, typed value, modification state, and validation errors.
- Column resize, hide, reorder, pin, and layout reset.
- Server-side filter and multi-sort controls with typed operators.
- Copy cell, row, selection, current page, and bounded result formats.
- Detail inspection for large, binary, structured, or narrow-screen content.
- A loading row for incremental fetch, plus error and retry state scoped to the failed page.

Selection stores stable identities rather than entire records where possible. Select All means the explicit current filter, not every record silently loaded into the client.

## Visual language

Database reuses Edith theme surfaces, typography, spacing, buttons, fields, focus rings, loading states, and motion preferences. Semantic system colors communicate status through paired icons and text. No fixed light or dark background is introduced.

Dense data content uses the repository monospaced style where values benefit from alignment. Headers and connection context remain readable at large text sizes. Animations honor reduced motion.

## Accessibility

Every connection, tree item, tab, grid cell, editor, dialog, menu, chart, and operation exposes an accessible name and state. Loading, partial results, cancellation, connection loss, mutation validation, and completion issue polite announcements. Destructive confirmation and authentication failure use assertive announcements.

Keyboard focus follows these rules:

1. Opening a sheet focuses its heading or first invalid control.
2. Closing restores the invoking control when it still exists.
3. Refresh preserves the selected stable object or moves to the nearest valid parent.
4. A completed operation does not steal focus.
5. A grid page change keeps the focused column when possible.

Charts always provide a data table and textual summary. Status never relies only on color. Hit targets remain at least 28 points on desktop and expand in very narrow layouts. Large text can turn horizontal form rows into vertical groups without clipping actions.

## Complete states

Every main surface implements initial, empty, loading, incremental, partial, stale, permission-limited, read-only, disconnected, reconnecting, cancelled, recoverable error, terminal error, mutation preview, mutation success, and background-operation states.

A surface never replaces already useful bounded data with a blank loading screen during refresh. Stale content remains labeled until replacement arrives or the user clears it.
