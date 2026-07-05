# Coding-Agent - Usage Observatory

A self-contained dashboard for observability into my AI coding-agent spend,
broken down by **date**, **model**, **token type**, and **tool**. Data comes
straight from the [`ccusage`](https://www.npmjs.com/package/ccusage) CLI (which
now detects Claude Code, OpenCode, Codex, and more); the dashboard inlines it
into a single HTML file so it works when opened directly (no server, no fetch).

The default view shows **Claude Code only** for the current billing cycle; the
other tools are one click away in the Source filter (and the billing cycle -
configurable via the billing-day input - is shared across all of them).

## Files

| File | What it is |
|---|---|
| `dashboard.html` | **Generated.** The self-contained dashboard (inline CSS + bundled JS + the `<script id="usage-data">` data block). Open it directly in a browser. Don't hand-edit - edit the sources and rebuild. |
| `js/*.js`, `css/styles.css` | **Source.** The dashboard as ~10 focused ES modules + its stylesheet. |
| `dashboard.template.html` | **Source.** The HTML shell (markup + `<link>`/`<script src>` placeholders the build inlines into). |
| `build.mjs` | Build step (run with **bun**): inlines `css/styles.css` + the bundled `js/app.js` graph into the template → `dashboard.html`, preserving the data block. |
| `render.mjs` | Assembles `data/usage.json` from the per-agent ccusage manifest and inlines it into `dashboard.html`. Also inlines `data/limits-history.jsonl` into the `<script id="limits-data">` block (raw for the last ≤7 days, hourly maxima beyond that). |
| `merge.mjs` | Pure helpers: normalizes each ccusage agent's daily schema into one shape and defines the source→tool grouping. Unit-tested. |
| `limits.mjs`, `js/limitsChart.js` | Limits-history helpers (pure, shared with render.mjs like merge.mjs) + the Limits card (Chart.js). |
| `cc-update` | The script you run. Pulls usage → renders. With `--push`, also commits & pushes. |
| `data/usage.json` | Historical snapshot (written each run; committed on `--push`). |
| `data/limits-history.jsonl` | Limit-poll history, appended by the Edith app (one JSON line per changed poll). |
| `com.pulkit.ccusage-dashboard.plist` | launchd schedule - runs `cc-update --push` daily at 10:00. |

## Use it

```bash
./cc-update              # refresh locally only (no git)
./cc-update --push       # refresh + commit + push to GitHub
open dashboard.html      # view
```

`cc-update` uses `bunx ccusage@latest` by default. If you install ccusage
globally, point it at the binary: `CCUSAGE_CMD=ccusage ./cc-update`.

## Develop the dashboard

The dashboard is authored as ES modules under `js/` (+ `css/styles.css`), then
bundled into the single self-contained `dashboard.html`:

```bash
# edit js/*.js, css/styles.css, or dashboard.template.html, then:
bun build.mjs            # regenerates dashboard.html (works on file:// and http)
open dashboard.html
```

`dashboard.html` is a build artifact - don't edit it directly. Data refreshes
(`cc-update` → `render.mjs`) write into the inlined `<script id="usage-data">`
block and don't require a rebuild; only code/style changes do.

## Schedule it (daily at 10:00)

```bash
cp com.pulkit.ccusage-dashboard.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.pulkit.ccusage-dashboard.plist
launchctl start com.pulkit.ccusage-dashboard   # run once now to test
```

Logs land in `/tmp/ccusage-dashboard.{out,err}.log`.

## Data sources & scope

Each **source** is one ccusage agent stream. `cli` + `cowork` roll up under the
**Claude Code** tool (the default filter); every other agent is its own tool:

- **Claude Code** - `cli` (the normal logs in `~/.claude`) + `cowork`
  (local-agent mode runs Claude Code under the hood, logging into nested
  `.claude` dirs under the desktop app -
  `~/Library/Application Support/Claude/local-agent-mode-sessions/**`; `cc-update`
  points `ccusage` at every such dir via `CLAUDE_CONFIG_DIR`).
- **OpenCode / Codex / …** - any other agent ccusage detects with data
  (`codex opencode amp droid copilot gemini …`). Their multi-model spend
  (e.g. `gpt-5.5`) is priced by ccusage directly.

`cc-update` calls `ccusage <agent> daily|session --json` **per agent** (not the
bare `ccusage daily`, which in ccusage 2.x sums every agent and would fold the
other tools into the Claude Code totals), then hands `render.mjs` a manifest of
the per-agent files. Agent daily schemas differ - Claude has per-model
`modelBreakdowns`, Codex uses `models{}` + `costUSD`, OpenCode gives only
row-level totals + `modelsUsed` - so `merge.mjs::normalizeAgentDaily` flattens
all three into one shape (OpenCode multi-model days are split equally, since
ccusage exposes no per-model breakdown for them).

The per-project / per-hour / per-chat **drilldowns** are built from raw JSONL
transcripts and exist for **Claude Code only** - other agents get
date / model / token-type / source, but no project tree.

**Cursor is not included.** Cursor keeps no local token/cost data (its
`~/.cursor/**` JSONL transcripts hold chat content only, no usage); real Cursor
spend lives server-side and is reachable only via the `cursor.com` usage API
using the local session token - a separate, more fragile path planned as a
follow-up.

## Dashboard features

- **KPIs**: total spend, avg/day (with peak day), total tokens, cache hit rate, top model, current-month projection, and **Cowork share** (when Cowork data exists).
- **Daily spend** with 7-day & 30-day rolling averages (burn rate).
- **Token mix** by day (input / output / cache write / cache read).
- **Share by model** donut + **model split over time** stacked bars.
- **Spend by source over time** - Code vs Cowork, stacked per day.
- **Cache efficiency** over time - `cache-read / (cache-read + input)`.
- **By day of week** - average per weekday.
- **Activity calendar** - GitHub-style daily-intensity heatmap.
- **Models table** - sortable columns.
- **Filters** sync to the URL query string (`?range=&metric=&models=&sources=`),
  so a filtered view is shareable and reload-safe: date range (7/30/90/All),
  Cost↔Tokens toggle, per-model multi-select, **per-source multi-select**, and Reset.

**Light / dark mode**: a toggle (top-right) switches themes; it defaults to your
OS `prefers-color-scheme` and persists via the `?theme=` URL param (no
localStorage). Reset reverts to the OS preference.

All charts use Chart.js 4.5 from the jsDelivr CDN allowlisted for Cowork
artifacts; the page is responsive down to ~380px.
