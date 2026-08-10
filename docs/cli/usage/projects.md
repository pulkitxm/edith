# `ed usage projects`

Cost and tokens per project, from the per-project rollup the collector attaches
to each day.

```
ed usage projects [--range <range>] [--limit <n>] [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--range` | `today`, `week`, `month`, `all` | `all` | Which days to include |
| `--limit` | integer greater than zero | `25` | Show at most this many projects, taken from the top of the cost order |
| `--json` | flag | off | Emit JSON on stdout |

This is the one window command that does not take `--source`. It declares its
own `--range`, so `--source` here is an unknown option and exits 2.

## `--json` shape

A top-level array sorted by `cost` descending, truncated to `--limit`. The
per-project rows carry only cost and tokens, not the six-field totals object the
other commands use.

```json
[
  {
    "cost": 1837.7667801071357,
    "project": "noveum-app-nextjs",
    "tokens": 1887083203
  },
  {
    "cost": 1340.774043018298,
    "project": "edith",
    "tokens": 1664124164
  },
  {
    "cost": 988.1540715389959,
    "project": "fable",
    "tokens": 919092634
  }
]
```

## Examples

```
ed usage projects
ed usage projects --range week --limit 5
ed usage projects --range today --json | jq -r '.[] | .project'
```

## Behaviour

Reads only, mutates nothing, and needs no app. It exits 4 with no `usage.json`,
1 on a file that will not decode, 3 on a bad `--range`, and 2 on `--limit 0` or
a negative limit, which is checked as "must be greater than zero" rather than
read as "all of them".

A project's name is the collector's `projectName`, falling back to its path and
then to the literal `unknown`. Names come from the git root of the working
directory a chat ran in, which is why a chat run inside a worktree is attributed
to the repository rather than to the worktree folder, and why a machine's remote
projects arrive suffixed with the machine name.

These numbers come from a different part of the file than every other verb here:
`ed usage summary`, `daily` and `models` read `bySource`, while `projects` reads
the `projects` array. They are derived from the same transcripts but rolled up
separately, so the project totals will not tie out to the summary totals to the
cent, and no `--source` filter applies to them.

```
$ ed usage projects --range week --limit 5
PROJECT            COST     TOKENS
noveum-app-nextjs  1837.77  1887083203
edith              1340.77  1664124164
fable              988.15   919092634
macos              303.80   383653333
x-convo-exporter   228.97   191821868
```

## Where to go next

- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
