# Database workbench

The workbench uses native AppKit tables inside focused SwiftUI surfaces. The
component split and viewport-oriented rendering take design inspiration from
[TablePro](https://github.com/TableProApp/TablePro).

## Ownership

The implementation lives under `Packages/Edith/Sources/Edith/Features/Database`.

- `DatabaseWorkbenchView` owns the connection state, object navigator, and tab strip.
- `DatabaseWorkbenchTabView` owns the Browse, Query, and Structure surfaces.
- `DatabaseRecordInspector` owns record details and edit forms.
- `DatabaseDataWorkspaceModel` owns request cancellation, result publication,
  pagination, filters, and sorting. Its Queries, Values, Editing, and Mutations
  extensions hold the corresponding conversion and editing logic.
- `DatabaseTableTab` retains the query draft, column preferences, scroll offset,
  mode, and session-only query history for one object.

Structure uses metadata from the last successful browse of the selected object.
A query projection cannot replace it. Changing objects or connections clears it.
Entering Structure does not fetch another page or discard the current query draft.

## Rendering and memory bounds

`DatabaseNativeTableView` reuses native cells and keeps tables mounted while
switching tabs. A consecutive append revision updates the row count without
reloading visible cells. Replacements, schema changes, palette changes, and
editing-policy changes invalidate the projection and reload.

`DatabaseGridProjection` indexes at most 128 visited rows. Cell previews inspect
only a 513-character prefix and render at most 512 characters, including the
truncation marker. The native field editor receives the full value before editing.
Document-tree nodes construct only their immediate children when requested.

Query history holds at most 20 entries per tab, each at most 16 KiB of UTF-8 text.
Oversized queries remain runnable but are not retained in history. Commands are
never truncated for reuse, and history is discarded with its tab.

## Regression checks

`make ci-performance` checks the performance contracts and database source-size
budgets. New database UI components are limited to 700 lines; explicit budgets
for older large components prevent further growth.

`Packages/Edith/test.sh --batch database-ui` covers native pagination and cell
reuse, full-value editing, bounded caches and previews, query history, schema
ownership, tab retention, and workbench rendering in light and dark appearances.
The large-value preview benchmark prints timings rather than enforcing a
machine-dependent wall-clock threshold. Correctness and memory bounds are
asserted deterministically.

To capture the actual workbench with synthetic fixtures, set
`EDITH_DATABASE_WORKBENCH_EVIDENCE_DIR` to a private temporary directory and run
the `finishedWorkbenchModesRenderWithSyntheticData` test through `test.sh`.
The fixture supplies mock database responses and captures only its own window.
