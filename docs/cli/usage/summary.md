# `ed usage summary`

Totals cost and tokens over a window, then breaks the same totals down by
source. This is what a bare `ed usage` runs.

```
ed usage summary [--range <range>] [--source <source>]... [--machine <machine>]... [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--range` | `today`, `week`, `month`, `all` | `all` | Which days to include: today only, the last 7 days, the last 30 days, or everything on file |
| `--source` | string, repeatable | every source | Count only these source ids. Repeat the flag to include several. An id the file does not list is an error |
| `--machine` | machine name, ssh alias, id, or `local` | every machine | Count only the agents that ran on these machines. `local` is this Mac. Repeat the flag to include several. Union with `--source` rather than an intersection |
| `--json` | flag | off | Emit JSON on stdout |

## `--json` shape

```json
{
  "bySource": {
    "cli": {
      "cacheCreationTokens": 175571245,
      "cacheReadTokens": 5445483888,
      "cost": 5094.730294150003,
      "inputTokens": 348913,
      "outputTokens": 16022050,
      "tokens": 5637426096
    },
    "codex": {
      "cacheCreationTokens": 0,
      "cacheReadTokens": 39030016,
      "cost": 28.771853,
      "inputTokens": 919731,
      "outputTokens": 155273,
      "tokens": 40105020
    }
  },
  "days": 7,
  "generatedAt": "2026-08-08T16:44:18Z",
  "range": "week",
  "totals": {
    "cacheCreationTokens": 175571245,
    "cacheReadTokens": 5484513904,
    "cost": 5123.502147150003,
    "inputTokens": 1268644,
    "outputTokens": 16177323,
    "tokens": 5677531116
  }
}
```

`tokens` is the sum of the other four token fields, not a separate figure from
the collector. `days` counts the days in the window that exist in the file, not
the length of the window, so a `week` range over four days of history reports
`4`. `generatedAt` is the string `usage.json` carries verbatim, and is `null`
when the file has no such field; `ed` does not reformat it.

## Examples

```
ed usage summary
ed usage summary --range week
ed usage summary --range month --source cli --source codex
ed usage summary --range today --json | jq .totals.cost
```

## Behaviour

Reads only, mutates nothing, and needs no app. It exits 4 when `usage.json` is
missing, 1 when the file is there but will not decode, and 3 when `--range` is
not one of the four ranges.

`--source` is validated against the file. An id nobody recognises exits 3 with
`no usage source named <id>`, hinted with the ids the file does list, or with a
pointer to `ed usage refresh` when it lists none, so a typo can no longer come
back as a confident all-zero report. Run `ed usage sources` first to get ids
that exist. `--machine` is checked the same way: a machine nothing was collected
from exits 3 with `no collected usage from a machine called <name>`.

The human output puts three lines above the table, a dollar sign only on the
cost line, and orders the table by source id:

```
$ ed usage summary --range week
cost    $5123.50
tokens  5677531116
days    7

SOURCE  COST     TOKENS
cli     5094.73  5637426096
codex   28.77    40105020
```

## Where to go next

- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
