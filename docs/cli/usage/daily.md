# `ed usage daily`

One row per day in the window, cost and tokens.

```
ed usage daily [--range <range>] [--source <source>]... [--machine <machine>]... [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--range` | `today`, `week`, `month`, `all` | `all` | Which days to include |
| `--source` | string, repeatable | every source | Count only these source ids. Repeat the flag to include several. An id the file does not list is an error |
| `--machine` | machine name, ssh alias, id, or `local` | every machine | Count only the agents that ran on these machines. `local` is this Mac. Repeat the flag to include several. Union with `--source` rather than an intersection |
| `--json` | flag | off | Emit JSON on stdout |

## `--json` shape

A top-level array sorted by `date` ascending. `totals` is the same six-field
object `ed usage summary` uses.

```json
[
  {
    "date": "2026-08-07",
    "totals": {
      "cacheCreationTokens": 26904348,
      "cacheReadTokens": 670275994,
      "cost": 647.5789594999999,
      "inputTokens": 180723,
      "outputTokens": 3836938,
      "tokens": 701198003
    }
  },
  {
    "date": "2026-08-08",
    "totals": {
      "cacheCreationTokens": 15319939,
      "cacheReadTokens": 765744244,
      "cost": 587.5631597500012,
      "inputTokens": 97362,
      "outputTokens": 3066068,
      "tokens": 784227613
    }
  }
]
```

## Examples

```
ed usage daily --range week
ed usage daily --range month --source codex
ed usage daily --json | jq -r '.[] | [.date, .totals.cost] | @tsv'
```

## Behaviour

Reads only, mutates nothing, and needs no app. Same exit codes as
`ed usage summary`: 4 with no `usage.json`, 1 on a file that will not decode, 3
on a bad `--range` or a `--source` the file does not list.

Days are not filtered out by `--source`. A day that exists in the window but has
no rows for the sources you asked for still gets a row, with every total at
zero, so the date sequence stays continuous over the days the collector saw. It
is still not a calendar: days the collector never recorded are absent, not
zero-filled.

```
$ ed usage daily --range week
DATE        COST     TOKENS
2026-08-02  620.79   877878788
2026-08-03  761.36   729558198
2026-08-04  547.72   705959878
2026-08-05  1035.51  535978079
2026-08-06  922.99   1342730557
2026-08-07  647.58   701198003
2026-08-08  587.56   784227613
```

## Where to go next

- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
