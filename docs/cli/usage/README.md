# `ed usage`

`ed usage` reports what your coding agents cost and how close you are to a
provider's rate limit. It reads the two files behind the app's dashboard,
`usage.json` and `limits-history.jsonl`. Headline reports use the same canonical
daily provider totals as the UI, while the repository report reconciles folder
detail to those totals. Reach for it when you want a spend figure in a script,
a repository breakdown without opening the window, or a gate on how much
session budget is left.

Both files live in `Repo.dataDir`, which is
`~/Library/Application Support/Edith/data` unless the `repoPath` setting names a
confirmed development checkout, in which case it is `apps/dashboard/data` inside
that checkout. Every read verb here works whether or not Edith is running. Two
invocations go further. `ed usage refresh` runs the collection pipeline itself,
in this process, and rewrites `usage.json` with the app open or closed.
`ed usage limits --refresh` asks the app to poll the providers first, which
makes it the one invocation here that needs Edith running and exits 4 when it is
closed.

## At a glance

| Command | What it does |
| --- | --- |
| `ed usage` | Runs `ed usage summary`, the default subcommand |
| `ed usage limits` | Session and weekly rate limits per provider, newest observation per provider |
| `ed usage summary` | Cost and tokens over a window, in total and per source |
| `ed usage daily` | Cost and tokens per calendar day, oldest first |
| `ed usage models` | Tokens and attributable cost per model, with unassigned provider cost shown separately |
| `ed usage projects` | Cost and tokens per GitHub repository, most expensive first |
| `ed usage sources` | The agents that produced the history, with their ids |
| `ed usage machines` | Runs `ed usage machines ls`, the default subcommand |
| `ed usage machines ls` | Every configured machine, whether it is counted, and what it adds up to |
| `ed usage machines collect` | Runs the collector on a machine over SSH and brings its numbers back |
| `ed usage machines enable` | Counts a machine on every later refresh |
| `ed usage machines disable` | Stops collecting from a machine, keeping what it already gave |
| `ed usage machines forget` | Drops what a machine gave and stops counting it |
| `ed usage refresh` | Re-collects usage data from every agent on this Mac |

## Commands

- [`ed usage limits`](./limits.md)
- [`ed usage summary`](./summary.md)
- [`ed usage daily`](./daily.md)
- [`ed usage models`](./models.md)
- [`ed usage projects`](./projects.md)
- [`ed usage sources`](./sources.md)
- [`ed usage machines`](./machines.md)
- [`ed usage refresh`](./refresh.md)

## Exit codes

| Code | When this group produces it |
| --- | --- |
| 0 | The command printed its report, or the refresh finished. Also a read that legitimately found nothing to show |
| 1 | `usage.json` exists but will not decode: `could not read <path>: <reason>` |
| 2 | `--limit 0` or a negative limit on `ed usage projects`, plus the usual parse failures, an unknown flag, a missing value, or `--source` passed to `ed usage projects` |
| 3 | `--range` is not `today`, `week`, `month` or `all`, and the hint lists the four. Also a `--source` id or a `--machine` the file knows nothing about |
| 4 | No `usage.json` at all; no rate limit history at all; a usage refresh whose pipeline failed, or `--follow` with nothing running; or Edith not running, or not answering, for `ed usage limits --refresh` |

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
  for `models` and `projects`, and the file's own order for `sources`.
- The read verbs never reach the network and only ever show the last thing that
  was written. `ed usage limits --refresh` posts a request and waits for the app
  to do the polling, while `ed usage refresh` runs the collector in this
  process, which makes it the one invocation here that goes out and fetches
  anything itself.
- Both refreshing invocations fail rather than reporting stale numbers, so exit
  0 from either does mean the work happened. `observedAt` can still repeat after
  `ed usage limits --refresh`, because the app appends a history row only when
  the values changed.
- `ed config set tabUsageEnabled false` turns off the Agent Usage extension, and
  with it the app's own collection and the limit polling; `claudeLimitsEnabled`
  and `codexLimitsEnabled` do the same for a single provider's polling.
  `ed usage refresh` runs the pipeline itself and collects either way. The read
  verbs keep working against whatever was collected before that, so
  `ed usage limits` goes on printing a silenced provider's last row until it
  scrolls out of the 8 KB tail.

## Where to go next

- [`ed config`](../config/README.md) for `tabUsageEnabled`, `claudeLimitsEnabled`,
  `codexLimitsEnabled` and `repoPath`, which decide what gets collected and
  where it lands
- [`ed extensions`](../extensions/README.md) for turning the Agent Usage extension on
  and off by id
- [`ed permissions`](../permissions/README.md) for the grants the app needs before it
  can collect anything
- [`ed system`](../system/README.md) for this Mac's metrics, the other read-only
  reporting group
- [All `ed` commands](../README.md)
