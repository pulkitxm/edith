# `ed jev ask`

Sends a raw System One request through the agent and prints the answers. It is
meant for scripts and agents that want a typed decision without their own key.

```
ed jev ask [--request <file>|-] [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--request <file>` | path, or `-` for stdin | `-` | The request document |
| `--json` | flag | off | Emit JSON on stdout |

The document has a `state` (a string or a flat object of strings) and named
`questions`. `model` defaults to `jev-latest`.

```json
{
  "state": { "ticket": "I was charged twice" },
  "questions": {
    "team": {
      "type": "choice",
      "instructions": "Which team owns `ticket`?",
      "criteria": { "billing": "Payments and refunds", "tech": "Bugs and outages" }
    },
    "urgent": { "type": "noul", "instructions": "`ticket` needs a reply today." },
    "mood": { "type": "score", "instructions": "How upset is the customer?", "criteria": ["Calm", "Upset", "Angry"] }
  }
}
```

A choice takes 2 to 255 options and a score 2 to 10 levels. Identical requests
within ten minutes are answered from the agent's cache.

## `--json` shape

`answers` maps each question to `type` plus `noul`, `choice`, `probabilities`,
`score` and `confidence` as they apply, and `latencyMs` is the round trip.

- [`ed jev`](./README.md)
- [All command groups](../README.md)
