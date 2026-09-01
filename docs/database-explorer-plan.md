# Database Explorer Plan

## Product goal

Build a calm, fast database viewer where people can find records, inspect values, and perform the safest CRUD operations supported by the connected database. The explorer should feel like a native data ledger, not a database administration suite.

The primary workflow is:

1. Pick a connection and object.
2. Narrow the result with visible, type-aware filters.
3. Sort and inspect a bounded page.
4. Create, edit, or delete one record when the live connection and record identity make that safe.
5. Review the exact mutation before applying it.

## Product boundaries

### In scope

- Object navigation for databases, schemas, tables, views, keyspaces, collections, and indexes.
- A responsive native grid with compact density, subtle hierarchy, and no cell borders.
- Type-aware filters with multiple clauses, explicit AND or OR joins, removable chips, and clear-all.
- Ordered multi-column sorting with visible priority.
- Bounded pagination and result-count accuracy labels.
- Column visibility, ordering, sizing, and per-object persistence.
- A row, document, or key inspector that becomes an editor when mutation capabilities allow it.
- Single-record create, update, and delete with policy, capability, identity, and concurrency checks.
- Read-only native query entry as a secondary workflow.
- Keyboard navigation, accessibility labels, loading states, empty states, errors, and cancellation.

### Intentionally out of scope

- Charts, dashboards, maps, and general visualization builders.
- ER diagrams, schema designers, migrations, and schema comparison.
- Monitoring, profiling, slow-query analysis, server administration, backup, and restore.
- Bulk updates, bulk deletes, broad import or export, ETL, and data synchronization.
- Unbounded reads or client-side loading of an entire table.
- Arbitrary write queries in the query editor.
- Generic update or delete behavior when a database cannot prove a stable unique identity.

## Research synthesis

The design takes interaction ideas from the reference applications, but does not copy their source or make them runtime dependencies.

| Reference | Useful patterns | What to adopt | What to leave out |
| --- | --- | --- | --- |
| [Tabularis](https://github.com/TabularisDB/tabularis) | Focused workspace, inline result editing, detachable results, broad driver model | Clear object-to-result flow, native-feeling editing, adapter capability boundaries | Notebooks, charts, assistant features, plugin authoring, visual explain |
| [RedisInsight](https://github.com/redis/RedisInsight) | SCAN-based browsing, key pattern and type filters, TTL visibility, type-specific value views | Safe incremental key discovery, key and type filters, TTL editing, bounded previews | Profiler, SlowLog, Pub/Sub, tutorials, recommendations, bulk delete |
| [TablePro](https://github.com/TableProApp/TablePro) | Native grid, inline edit, sort, filter, undo and redo, keyboard-first navigation | Low-latency native table interactions, column controls, direct edit entry points | Multi-window power-user surface, assistant features, broad plugin system |
| [DbGate](https://github.com/dbgate/dbgate) | Excel-like filters, SQL change preview, form view, JSON view, related-data workflows | Filter builder, change review, side inspector, document source view | Query designer, ERD, schema editing, charts, maps, import and export suite |
| [ClickHouse](https://github.com/ClickHouse/ClickHouse) | Bounded query tooling, strong metadata model, insert-oriented storage | Keyset browsing, server-side filtering, safe single-row inserts | Generic row update and delete based on primary-key metadata |

Tabularis is Apache-2.0, TablePro is AGPL-3.0, and DbGate is GPL-3.0. RedisInsight uses its own source-available license. The implementation should continue to use these projects only for product research unless a separate dependency and license review explicitly approves reuse.

## Experience architecture

### Wide layout

- Left: resizable object navigator with search, grouped object kinds, lazy loading, and refresh.
- Center: browse or query mode, filter ribbon, table grid, and compact result footer.
- Right: row, key, or document inspector only while a record is selected or edited.
- The inspector can move below the grid when the available width is insufficient.

### Compact layout

- Replace the object sidebar with a single object menu.
- Stack browse controls and connection actions in two short rows.
- Keep filters horizontally scrollable and preserve their full meaning.
- Put the inspector below the grid with a bounded height.
- Preserve horizontal table scrolling instead of crushing columns.

### Visual language

- Warm canvas and panel tones with one theme-derived accent.
- No vertical or horizontal cell grid lines.
- Thirty-point rows, restrained zebra tint, and rounded hover and selection fills.
- One subtle divider beneath column headers and between major regions.
- Monospaced values, compact system labels, and quiet metadata.
- Destructive controls use color only as a secondary cue and always include an accessible label.
- Avoid permanent toolbars full of icons. Show controls where they affect the current object or selection.

## Shared browsing controls

### Object navigator

- Search object names within the loaded metadata.
- Group by database or schema, then object kind.
- Show table, view, collection, index, and keyspace icons consistently.
- Show approximate row or key count only when the adapter reports it.
- Lazy-load large namespaces and expose a clear load-more affordance.
- Preserve the selected object per connection during the session.
- Show permission-limited metadata as degraded, not as an empty database.

### Filter ribbon

- Add a filter from a field menu or a compact plus control.
- Choose a field, a type-valid operator, and a value.
- Operators by type:
  - Text: equals, not equals, contains, starts with, ends with, is null, is not null.
  - Number: equals, not equals, greater than, at least, less than, at most, is null, is not null.
  - Date and time: before, on or before, equals, on or after, after, is null, is not null.
  - Boolean: is true, is false, is null, is not null.
  - UUID and identifiers: equals, not equals, is null, is not null.
  - Redis key: equals, contains, starts with, ends with.
  - Redis type: equals a supported Redis data type.
- Combine clauses with an explicit AND or OR control.
- Render applied filters as readable chips with edit and remove actions.
- Keep case sensitivity aligned with server semantics and label any forced behavior.
- Apply filters server-side and reset pagination when they change.
- Preserve draft text when a filter popover is temporarily closed.
- Support keyboard apply with Return and dismiss with Escape.
- Future refinement: saved filter presets scoped to one connection and object.

### Sorting

- Click a header to cycle ascending, descending, and off.
- Shift-click to add or alter a secondary sort.
- Show sort direction and numeric priority in the header or active-sort chips.
- Always append a stable identity tie-breaker when the adapter requires deterministic pagination.
- Reset pagination after sort changes.

### Columns

- Provide a Columns menu beside the filters.
- Toggle individual fields, show all, and reset to the object default.
- Keep at least one data field visible.
- Reorder visible fields through a menu move action, keyboard command, or header drag when reliable.
- Persist field order, visibility, and widths by connection plus full object identifier.
- Prune removed fields and append newly discovered fields without destroying the user's valid preferences.
- Keep identity fields discoverable even when hidden from the grid.
- Future refinement: pin the row identity column and one or more selected data columns.

### Pagination and result status

- Keep every request bounded by adapter page and byte limits.
- Show loaded records, exact or estimated total, and completeness such as complete, sampled, or truncated.
- Provide load-more for continuation-based adapters.
- Add page-size choices only where the adapter can honor them safely.
- Preserve scroll position while appending.
- Cancel an active read when the object, filters, sort, or connection changes.
- Never imply a full count when the server only supplied an estimate.

### Selection and inspection

- Single click selects a row and opens details without entering edit mode.
- Double click enters edit mode only when the row and capability are editable.
- Present every field in a vertically scrollable form for wide records.
- Show null, missing, binary, truncated, and unsupported values distinctly.
- Offer tree and source views for documents.
- Keep identity components visible and non-editable.
- Future refinement: copy cell, copy row as JSON, and copy selected values using a small context menu.

## Mutation workflow

Every write follows the same guarded path:

1. The adapter reports the live operation capability as available.
2. Connection, environment, topology, and production policies permit writes.
3. The selected object kind permits the requested operation.
4. Update and delete require an adapter-proven stable identity.
5. Values are parsed by field type and transported as bound values, never interpolated input.
6. The app shows a safety review with target, operation, identity, and changed values.
7. The adapter revalidates mutable metadata when that metadata is part of the safety proof.
8. Apply succeeds only for the expected mutation count or product concurrency token.
9. The grid refreshes and reports stale or conflicting data without silently overwriting it.

Create and edit forms should include only supported fields. Generated, computed, and identity fields remain read-only. Null is an explicit action, not an empty-string convention. Cancel must discard drafts without changing the database.

## Database capability matrix

Legend: `Yes` is in the current explorer path, `Guarded` has stricter product checks, `Planned` belongs in the focused roadmap, and `No` is intentionally excluded.

| Product | Browse and filter | Create | Update | Delete | Product-specific explorer behavior |
| --- | --- | --- | --- | --- | --- |
| PostgreSQL | Yes | Yes | Yes | Yes | Schema and table navigation, keyset or offset paging, typed predicates, primary or unique row identity, bound mutations, exact affected-row reconciliation |
| MySQL | Yes | Yes | Yes | Yes | Database and table navigation, typed predicates, primary or unique identity, server read-only detection, bound mutations with one-row limits |
| MariaDB | Yes | Yes | Yes | Yes | First-class product identity with MySQL-family behavior, server read-only detection, canonical bound mutations |
| SQLite | Yes | Yes | Yes | Yes | File or memory connection, offset paging, live primary-key or rowid revalidation, immediate transaction, rollback unless exactly one row changes |
| Redis | Yes | String keys | String value and TTL | Key | SCAN only, key pattern and Redis 6+ type filters, type and TTL columns, bounded previews for string, hash, list, set, sorted set, and stream |
| Valkey | Yes | String keys | String value and TTL | Key | Redis-compatible safe keyspace path with capability discovery from the connected server |
| MongoDB | Yes | Yes | Yes | Yes | Collection navigation, bounded document browse, JSON editor, `_id` identity, replace-one and delete-one semantics |
| Elasticsearch | Yes | Yes | Yes | Yes | Index navigation, JSON source view, point-in-time pagination, exact sequence-number and primary-term concurrency tokens |
| OpenSearch | Version-gated | Yes | Yes | Yes | Point-in-time browse on supported versions, JSON source view, guarded single-document concurrency |
| ClickHouse | Yes | Guarded | No | No | Non-null sorting-key browse, read-only query and explain, metadata-refreshed single-row insert only for writable non-system MergeTree tables and non-generated columns |

## Product-specific details

### PostgreSQL

- Navigate schemas, tables, and views.
- Use server-side typed predicates and deterministic multi-sort.
- Allow insert on writable tables.
- Allow update and delete only with non-null primary-key or unique-key identity.
- Keep identity columns read-only in row editing.
- Use bound parameters and require exactly one affected row for update and delete.
- Planned: expose enum choices, array and JSON field editors, and foreign-key value hints without turning the explorer into a relationship browser.

### MySQL and MariaDB

- Navigate databases, tables, and views.
- Detect server-level `read_only` and `super_read_only` state.
- Use primary or unique key components as stable identity.
- Add `LIMIT 1` to guarded update and delete execution.
- Parse numeric, temporal, boolean, null, binary, and text values through the existing type codec.
- Planned: enum and set value menus, unsigned range feedback, and clearer zero-date handling.

### SQLite

- Treat file access mode as part of the write capability.
- Re-read table metadata before preview and apply.
- Prefer a declared primary key, otherwise use rowid only for rowid tables.
- Wrap each mutation in an immediate transaction.
- Roll back update and delete unless exactly one current row matches.
- Planned: surface WITHOUT ROWID status and generated-column reasons directly in the editor.

### Redis and Valkey

- Discover keys with SCAN, never KEYS.
- Escape user input before compiling MATCH patterns.
- Use TYPE filtering only when the connected server supports SCAN TYPE.
- Show loaded and scanned progress separately because SCAN is incremental.
- Display key, type, TTL, and a bounded value summary.
- Create string keys with optional TTL.
- Edit a string value and any key TTL, preserving the existing TTL unless changed.
- Delete one selected key after review.
- Planned: dedicated element inspectors and CRUD for hash fields, list positions, set members, sorted-set members, streams, and RedisJSON. Each editor must use bounded paging and product-native identity.

### MongoDB

- Navigate databases and collections.
- Use a filter builder for common scalar fields and a JSON query mode only within bounded safe operations.
- Show document tree and source views.
- Create a document, replace one document by `_id`, and delete one document by `_id`.
- Planned: type-preserving editors for ObjectId, date, decimal, binary, arrays, and nested paths, plus projection controls.

### Elasticsearch and OpenSearch

- Navigate indexes and show mapping-derived fields when permissions allow.
- Use point-in-time pagination and stable sort tokens.
- Show `_id`, source fields, and highlights without conflating metadata with document source.
- Create, replace, and delete one document.
- Require exact optimistic-concurrency tokens for replace and delete.
- Planned: a simple mapping-aware filter editor for keyword versus analyzed text, range fields, existence, and nested JSON paths.

### ClickHouse

- Navigate databases, tables, views, dictionaries, and supported engines.
- Browse only when a non-null sorting key supports deterministic keyset continuation.
- Keep the query editor read-only and accept bounded SELECT, WITH SELECT, and EXPLAIN forms.
- Insert one row only when the connection is writable and fresh metadata proves the target is a non-system MergeTree-family table.
- Reject generated columns and cast each bound input to the server-reported column type.
- Keep update and delete unavailable. ClickHouse primary and sorting keys define ordering and data skipping, not row uniqueness, so they cannot safely target one user-visible row.
- Reconsider update and delete only if a future adapter obtains a server-supported immutable row address and a compatible version-specific operation with clear concurrency behavior.

## States and feedback

- Empty: explain whether the user must choose a connection, object, or query.
- Loading: retain existing rows during refresh, show progress, and expose Cancel.
- Partial: label sampled or truncated results and explain the active bound.
- Permission-limited: keep available data visible and identify missing metadata permissions.
- Read-only: explain whether the cause is connection policy, environment protection, server topology, object kind, version, or missing row identity.
- Editing: keep the draft local until Review and Apply.
- Conflict: preserve the draft, explain that the row changed or disappeared, and offer Refresh.
- Failure: use a specific recovery action and do not discard successfully loaded rows.

## Keyboard and accessibility

- Arrow keys move table selection, Return opens details, and Escape closes a popover or editor.
- Command-Return reviews an edit or runs a read-only query, depending on the active region.
- Shift-click extends sort order.
- Every icon-only control has a label and help text.
- Cells expose the field name and rendered value to accessibility APIs.
- Row identity state is announced without relying on the key icon.
- Focus returns to the initiating cell or button after closing an inspector or filter.
- Selection, errors, production state, null, and missing values never rely on color alone.
- Minimum interactive target sizes and compact layouts must remain usable at increased text scale.

## Performance rules

- Virtualize rows through the native table and reuse cell views.
- Fetch only visible pages, bounded previews, and bounded metadata groups.
- Push filter and sort work to the adapter instead of filtering loaded rows.
- Debounce object search and future type-ahead value suggestions.
- Cancel superseded work and ignore stale generations.
- Keep continuation tokens connection-bound, request-bound, and time-bound.
- Limit rendered cell text while preserving the full bounded value in the inspector.
- Never compute a full count unless the adapter explicitly supports it within the operation budget.

## Delivery phases

### Phase 1: focused viewer and single-record CRUD

- Responsive object navigator, controls, grid, footer, and inspector.
- Borderless table styling with light and dark theme support.
- Multi-clause filters, AND or OR, active chips, and ordered multi-sort.
- Existing bounded pagination and cancellation.
- Capability-gated CRUD for PostgreSQL, MySQL, MariaDB, SQLite, Redis, Valkey, MongoDB, Elasticsearch, and OpenSearch.
- Guarded insert-only behavior for ClickHouse.
- Mutation review before every write.

### Phase 2: grid control and editing quality

- Persistent visibility, order, and width for columns.
- Context actions for copy cell and copy row as JSON.
- Better type-specific form controls for booleans, dates, enums, sets, null, and long text.
- Page-size control where supported and scroll preservation while appending.
- Clear stale-data conflict recovery.
- Complete keyboard focus and accessibility audit.

### Phase 3: narrow product refinements

- Redis collection element inspectors and CRUD with bounded element paging.
- MongoDB nested value editing and projection controls.
- Search mapping-aware operators and nested-path filters.
- Relational enum, set, JSON, array, and foreign-key value hints.
- ClickHouse insert batching only if it can preserve the review and bounded-safety model.

## Acceptance criteria

- A user can reach any supported data object without opening a query editor.
- Filters are the most prominent data control and compile to adapter-native bounded requests.
- The grid has no white cell lines in light or dark mode.
- Wide and compact layouts keep the object choice, filters, grid, result status, and inspector usable.
- Column preferences survive reopening an object and recover cleanly after schema changes.
- Every enabled mutation has a live capability, policy permission, compatible object, valid typed payload, and safety review.
- Relational update and delete never run without a stable non-null identity.
- Redis browsing never uses KEYS.
- Search document replacement and deletion never omit optimistic-concurrency tokens.
- ClickHouse update and delete never appear enabled from primary-key metadata alone.
- All requests remain within adapter record, byte, time, and continuation limits.
- The focused model and adapter test suites, application target build, and visual render checks pass.
