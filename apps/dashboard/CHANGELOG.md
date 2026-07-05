# Changelog

## 2026-07-04 - Limits card

Added a **Limits** card: session and weekly usage curves, threshold-rule
shading, and reset markers, over four ranges (24h / 7d / 30d / all).

### Data: limits-history.jsonl
The Edith app appends `data/limits-history.jsonl` on every changed poll (one
JSON line per session/weekly percent change). `render.mjs` inlines it into a
new `<script id="limits-data">` block - raw for the last ≤7 days, downsampled
to hourly maxima beyond that - so the card stays self-contained like the rest
of the dashboard, no fetch required.

### Dashboard
- New **Limits** card: session (5h) and weekly usage lines, colored by the
  default warn/critical thresholds (60% / 85%), with vertical markers at each reset.
- Range picker (24h / 7d / 30d / all), consistent with the rest of the
  filters.

## 2026-05-31 - Light / dark theme

Added a theme toggle (top-right). Defaults to the OS `prefers-color-scheme`,
switches instantly, and persists via the `?theme=` URL param (no localStorage,
consistent with the other filters). An inline `<head>` script applies the theme
before first paint to avoid a flash. Reset reverts to the OS preference.

Theme-aware throughout: CSS variables drive the page, and Chart.js colors
(grid, ticks, donut borders) plus the categorical palette are recomputed on
switch - the dark slate is lightened so CLI/source/token bars stay legible on a
dark background.

## 2026-05-31 - Cowork source + opt-in push (schema v2)

Include Cowork usage and split spend by source.

### Cowork usage now counted
Cowork (local-agent mode) runs Claude Code under the hood but logs into nested
`.claude` dirs under the desktop app, which `ccusage` never scans by default.
`cc-update` now discovers every such dir and runs `ccusage` per source via
`CLAUDE_CONFIG_DIR`. On this machine that surfaced ~$133 (≈20%) of previously
invisible spend. The `cc-usage` producer (`ccusage-total.mjs`) was updated the
same way - it points its `ccusage` calls and transcript walk at the Cowork dirs.

### Schema v2 (source split)
`data/usage.json` is now `schemaVersion: 2`:
`daily[].bySource{ cli:[modelBreakdown], cowork:[...] }`, per-source `totals.bySource`,
and a `sources` array. The dashboard derives every chart from `bySource`, so the
source filter and model filter both stay consistent. A v1 back-compat adapter
treats old flat `modelBreakdowns` as a single `cli` source.

### Dashboard
- New **Spend by source over time** chart (CLI vs Cowork, stacked per day).
- New **Cowork share** KPI (shown only when Cowork data exists).
- New **per-source** filter chips; `sources` added to the URL query params.

### cc-update: push is now opt-in
`cc-update` refreshes locally only by default; it commits & pushes **only** with
`./cc-update --push`. The launchd schedule passes `--push` so the daily run still
publishes.

## 2026-05-30 - Initial dashboard

Built the usage dashboard and update pipeline from scratch.

### Pipeline
- **`cc-update`** (bash): runs `ccusage daily --json` + `ccusage session --json`,
  calls `render.mjs`, then commits and pushes to GitHub. Idempotent - skips the
  commit when nothing changed. Defaults to `bunx ccusage@latest`
  (override with `CCUSAGE_CMD`).
- **`render.mjs`** (node): assembles `data/usage.json` (`schemaVersion: 1`,
  `generatedAt`, `totals`, `daily`, `sessions`) and inlines it into the
  `<script id="usage-data">` block of `dashboard.html`. The dashboard reads the
  inlined JSON - no `fetch` - so it works opened directly or in a sandbox.
- **`com.pulkit.ccusage-dashboard.plist`**: launchd schedule, daily at 10:00.

### Data scope (why no per-project charts)
The data source is the real `ccusage` CLI, which exposes per-**date** and
per-**model** breakdowns but **no per-project** data (`session --json` is keyed
by session id, not project path). The original spec's project views were
therefore dropped rather than faked. Everything is by date / model / token type.

### Dashboard (`dashboard.html`)
Light-mode, self-contained, Chart.js 4.5 (CDN-allowlisted), system fonts only
(editorial serif + monospace numerals - no web fonts, since the artifact sandbox
blocks font CDNs).

Visualizations and the insight each surfaces:
- **KPIs** - spend, avg/day + peak, tokens, cache hit rate, top model, and a
  month-end **projection** (MTD × days-in-month / days-elapsed).
- **Daily spend + burn rate** - bars with 7-day & 30-day rolling averages, so a
  spending trend is visible against day-to-day noise.
- **Token mix by day** - where tokens go (input vs output vs cache write/read).
- **Share by model** donut + **model split over time** - which model drives cost.
- **Cache efficiency** - `cache-read / (cache-read + input)` per day: is prompt
  caching actually paying off.
- **By day of week** - average spend per weekday (weekend bars distinguished).
- **Activity calendar** - GitHub-style heatmap of daily intensity.
- **Models table** - sortable, reflects current filters.

### Interaction
- Filters are in-memory and re-derived from the inlined data on every load (no
  `localStorage`): range (7/30/90/All), metric toggle (Cost ↔ Tokens), per-model
  multi-select, and Reset. The model filter recomputes each day's totals from the
  selected models' breakdowns, so it affects **every** chart consistently.
- Empty state shown when `daily` is empty.

### Verified
Headless-Chrome smoke test against a real 11-day / 4-model / 78-session payload:
no console errors, all charts non-blank, range + metric + model filters and reset
re-render correctly, sortable table works, empty-state triggers on `{}`, and no
horizontal overflow at 380px.
