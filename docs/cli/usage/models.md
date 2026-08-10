# `ed usage models`

Cost and tokens per model, so you can see which model is actually spending the
money.

```
ed usage models [--range <range>] [--source <source>]... [--machine <machine>]... [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--range` | `today`, `week`, `month`, `all` | `all` | Which days to include |
| `--source` | string, repeatable | every source | Count only these source ids. Repeat the flag to include several. An id the file does not list is an error |
| `--machine` | machine name, ssh alias, id, or `local` | every machine | Count only the agents that ran on these machines. `local` is this Mac. Repeat the flag to include several. Union with `--source` rather than an intersection |
| `--json` | flag | off | Emit JSON on stdout |

## `--json` shape

A top-level array sorted by `totals.cost` descending.

```json
[
  {
    "model": "claude-opus-5",
    "totals": {
      "cacheCreationTokens": 153031472,
      "cacheReadTokens": 4093821515,
      "cost": 3747.5389512500024,
      "inputTokens": 335270,
      "outputTokens": 13006480,
      "tokens": 4260194737
    }
  },
  {
    "model": "gpt-5.6-sol",
    "totals": {
      "cacheCreationTokens": 0,
      "cacheReadTokens": 39030016,
      "cost": 28.771853,
      "inputTokens": 919731,
      "outputTokens": 155273,
      "tokens": 40105020
    }
  }
]
```

## Examples

```
ed usage models
ed usage models --range week
ed usage models --range month --source cli
ed usage models --json | jq -r '.[0].model'
```

## Behaviour

Reads only, mutates nothing, and needs no app. Same exit codes as
`ed usage summary`.

A row whose model name is missing from the file is grouped under the literal
name `unknown` rather than dropped, so the model totals always add up to the
summary totals for the same window and sources.

```
$ ed usage models --range week
MODEL                      COST     TOKENS
claude-opus-5              3747.54  4260194737
claude-fable-5             1202.34  777247635
claude-sonnet-5            144.57   598911741
gpt-5.6-sol                28.77    40105020
claude-haiku-4-5-20251001  0.28     1071983
```

## Where to go next

- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
