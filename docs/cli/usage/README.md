# `ed usage`

`ed usage` reports what your coding agents cost and how close you are to a
provider's rate limit. It reads the two files behind the app's dashboard,
`usage.json` and `limits-history.jsonl`. Headline reports use the same canonical
daily provider totals as the UI, while the repository report reconciles folder
detail to those totals. Reach for it when you want a spend figure in a script,
a repository breakdown without opening the window, or a gate on how much
session budget is left.

Both files live in `~/Library/Application Support/Edith/data`. A development
build can point the whole data root somewhere else with the `EDITH_DATA_ROOT`
environment variable; there is no setting for it. Every read verb here works whether or not Edith is running. Two
invocations go further. `ed usage refresh` runs the collection pipeline itself,
in this process, and rewrites `usage.json` with the app open or closed.
`ed usage limits --refresh` asks the app to poll the providers first, which
makes it the one invocation here that needs Edith running and exits 4 when it is
closed.

## At a glance

| Command | What it does |
| --- | --- |
| `ed usage` | Runs `ed usage summary`, the default subcommand |
| `ed usage limits` | Included rate limits per provider, newest observation per provider |
| `ed usage alerts` | Burn rate, projected cap and the limit alert each tracked window would get now |
| `ed usage summary` | Cost and tokens over a window, in total and per source |
| `ed usage daily` | Cost and tokens per calendar day, oldest first |
| `ed usage models` | Tokens and attributable cost per model, with unassigned provider cost shown separately |
| `ed usage projects` | Runs `ed usage projects list`, the default subcommand |
| `ed usage projects list` | Cost and tokens per GitHub repository, most expensive first |
| `ed usage projects show` | One repository with every matching folder |
| `ed usage projects open` | Open a repository from the drilldown in the browser |
| `ed usage projects copy-link` | Copy a repository link from the drilldown |
| `ed usage projects copy-chat` | Copy a chat identifier from the drilldown |
| `ed usage attribution` | Runs `ed usage attribution ls`, the default subcommand |
| `ed usage attribution ls` | How unknown and non-GitHub folders were matched to repositories |
| `ed usage attribution reset` | Forget those decisions so the next refresh decides again |
| `ed usage sources` | The agents that produced the history, with their ids |
| `ed usage export` | Branded activity and milestone cards as PNG images |
| `ed usage machines` | Runs `ed usage machines ls`, the default subcommand |
| `ed usage machines ls` | Every configured machine, whether it is counted, and what it adds up to |
| `ed usage machines collect` | Runs the collector on a machine over SSH and brings its numbers back |
| `ed usage machines enable` | Counts a machine on every later refresh |
| `ed usage machines disable` | Stops collecting from a machine, keeping what it already gave |
| `ed usage machines forget` | Drops what a machine gave and stops counting it |
| `ed usage refresh` | Re-collects local usage and tops up counted machines that are stale |
| `ed usage statusline` | Runs `ed usage statusline status`, the default subcommand |
| `ed usage statusline status` | Whether Claude Code's status line feeds Edith, and when it last did |
| `ed usage statusline install` | Points Claude Code's status line at Edith so Claude limits flow in |
| `ed usage statusline remove` | Takes Edith out of Claude Code's status line |
| `ed usage statusline record` | Saves the windows Claude Code passes to its status line |

## Commands

- [`ed usage limits`](./limits.md)
- [`ed usage alerts`](./alerts.md)
- [`ed usage summary`](./summary.md)
- [`ed usage daily`](./daily.md)
- [`ed usage models`](./models.md)
- [`ed usage projects`](./projects.md)
- [`ed usage projects list`](./projects-list.md)
- [`ed usage projects show`](./projects-show.md)
- [`ed usage projects open`](./projects-open.md)
- [`ed usage projects copy-link`](./projects-copy-link.md)
- [`ed usage projects copy-chat`](./projects-copy-chat.md)
- [`ed usage attribution`](./attribution.md)
- [`ed usage sources`](./sources.md)
- [`ed usage export`](./export.md)
- [`ed usage machines`](./machines.md)
- [`ed usage refresh`](./refresh.md)
- [`ed usage statusline`](./statusline.md)

## Exit codes

| Code | When this group produces it |
| --- | --- |
| 0 | The command printed its report, or the refresh finished. Also a read that legitimately found nothing to show |
| 1 | `usage.json` exists but will not decode: `could not read <path>: <reason>` |
| 2 | `--limit 0` or a negative limit on `ed usage projects list`, an empty chat identifier, plus the usual parse failures, an unknown flag, a missing value, or `--source` passed to this group |
| 3 | `--range` is not `today`, `week`, `month` or `all`, a repository cannot be found uniquely, or a `--source` id or `--machine` is unknown |
| 4 | No `usage.json` at all; no rate limit history at all; a repository link or platform action is unavailable; a usage refresh whose pipeline failed, or `--follow` with nothing running; or Edith not running, or not answering, for `ed usage limits --refresh` |

## Notes and gotchas

- `ed usage` with no subcommand runs `ed usage summary`, so a bare `ed usage`
  prints the all-time totals rather than a help screen. `ed usage --help` is
  still the help screen, and exits 0.
- The two files are independent. `ed usage limits` reads only
  `limits-history.jsonl` and works with no `usage.json` at all; every other verb
  reads only `usage.json` and works with no limit history. Neither absence
  affects the other.
- `--range week` means Monday through today. `--range month` means today and the
  preceding 29 days. Both use your local calendar day and exclude future-dated
  rows.
- Cost and token figures are doubles all the way through, and the serialiser
  prints an integral double as an integer. `"percent": 30` is 30.0 and
  `"cost": 0` is a genuine zero, not a missing field.
- Token counts in the human tables are truncated to a whole number, not rounded,
  and costs are formatted to two decimal places. Only `--json` gives you the
  unrounded values.
- Object keys in `--json` are sorted, arrays keep the order the command chose:
  fixed provider order for `limits`, date ascending for `daily`, cost descending
  for `models` and `projects list`, and the file's own order for `sources`.
- The read verbs never reach the network and only ever show the last thing that
  was written. `ed usage limits --refresh` posts a request and waits for the app
  to do the polling, while `ed usage refresh` runs the collector in this
  process, which makes it the one invocation here that goes out and fetches
  anything itself.
- Refreshes retain previous history for a source that is temporarily unavailable
  and print a collection note. A successful refresh can therefore include saved
  provider usage. `observedAt` can still repeat after
  `ed usage limits --refresh`, because the app appends a history row only when
  the values changed.
- Claude limits come from Claude Code's status line, not from Anthropic.
  `ed usage statusline install` sets that up; until then the Claude ring reports
  that it needs the status line. See [`ed usage statusline`](./statusline.md).
- `ed config set tabUsageEnabled false` turns off the Agent Usage extension, and
  with it the app's own collection and the limit polling; `claudeLimitsEnabled`,
  `codexLimitsEnabled`, `cursorLimitsEnabled` and `grokLimitsEnabled` do the same
  for a single provider.
  `ed usage refresh` runs the pipeline itself and collects either way. The read
  verbs keep working against whatever was collected before that, so
  `ed usage limits` keeps printing a silenced provider's newest valid row.

## Attribution model

The daily and model rows are the authoritative accounting totals. The collector
discovers Claude Code, Cowork, Codex, Cursor, Grok, OpenCode, Amp, Droid,
Codebuff, Hermes, Pi, Goose, Kilo, Copilot, Gemini, Kimi, Qwen, OpenClaw and
Command Code when their local stores contain usage. A source appears in
`ed usage sources` only when it contributed data, so this list is collector
coverage rather than a promise that every id is present on every Mac.

Cloud coding tasks contribute separate `codex-cloud` (Codex Cloud) and
`claude-cloud` (Claude Code Web) sources, enabled by default. They use existing
CLI sign-ins: `codex login` and `claude auth login`. General ChatGPT and Claude
web conversations are excluded. SSH machine collection skips these account-wide
feeds so each account is fetched once on the collecting Mac.

Codex Cloud coverage is partial. Edith reads the signed-in user's daily workspace
analytics and counts web, mobile and integration launch surfaces. The feed groups
usage by launch surface, not execution location. Desktop and CLI launches can run
in Cloud environments, but those mixed surfaces are excluded because they also
contain usage already counted from local transcripts. This source therefore
omits Cloud tasks launched from desktop or CLI. The provider may return only
part of the requested history; an empty older period does not establish zero
lifetime usage. Refreshes print a note describing this limitation. Its dates are
provider UTC days. When the feed provides credits rather than USD, costs use
$0.04 per credit as a nominal equivalent, not an invoice amount. Purchased credit
discounts and included subscription allowances can change actual spend.
Account-wide model totals cannot identify the cloud model, so these rows have
an unattributed model and repository.

Claude Code Web reads cloud session usage receipts, including archived sessions,
and prices them using the same offline rate table as local Claude Code.
Only retrievable sessions contribute; permanently deleted sessions cannot be
reconstructed from this feed. An all-time report totals the available history,
which can be less than lifetime account usage.
It requires subscription OAuth credentials saved by a browser sign-in with
`claude auth login`, including cloud-session access. Console API keys and the
model-only tokens generated by `claude setup-token` cannot retrieve these web
sessions. Edith uses the saved browser login for this feed even when the CLI
uses `CLAUDE_CODE_OAUTH_TOKEN` for model requests.
Remote-control sessions are excluded. Receipts already present in local Claude
Code or Cowork transcripts are excluded by message identity. Request IDs are
optional; valid receipts without them still contribute usage. Only
usage metadata is saved in `cloud-history/claude.json`, never conversation text.
Unchanged sessions reuse that cache; failed requests can also reuse it while
still removing receipts resumed locally. A cloud sign-in without session access
produces an unavailable note and preserves prior history.

Repository detail comes from the session stores that expose it: Claude and
Cowork transcripts, Codex daily sessions and metadata, Cursor chat metadata
when a local chat matches the conversation, Pi session logs, Command Code
projects, Grok Build turn logs under `~/.grok/sessions`, and the OpenCode
database. Grok token totals split cache out of input, and the cost is the
billed `costUsdTicks` on each completed turn. Cursor token and cost totals come from
Cursor's authenticated usage API for the signed-in account, including IDE
requests. Local chat metadata attributes a conversation to a folder when that
chat exists on disk. Those measurements are reconciled per day and source to
the authoritative totals.
Detail is scaled down when it would exceed the total, and any remaining source
or model total with no reliable folder is emitted under the `Unattributed`
repository. That is why `ed usage projects list` adds back to `summary` without
pretending every provider cost belongs to a known folder.

Machine sources use the stable id
`machine:<lowercase-machine-uuid>:<agent>`, not the machine's editable name or
slug. Renaming a machine therefore preserves filters and attribution. Remote
paths use the same prefix, while GitHub repository ids remain shared across
machines so the same repository still groups into one row.

## Where to go next

- [`ed config`](../config/README.md) for `tabUsageEnabled`, `claudeLimitsEnabled`,
  `codexLimitsEnabled`, `cursorLimitsEnabled` and `grokLimitsEnabled`, which decide what gets collected
- [`ed extensions`](../extensions/README.md) for turning the Agent Usage extension on
  and off by id
- [`ed permissions`](../permissions/README.md) for the grants the app needs before it
  can collect anything
- [`ed system`](../system/README.md) for this Mac's metrics, the other read-only
  reporting group
- [All `ed` commands](../README.md)
