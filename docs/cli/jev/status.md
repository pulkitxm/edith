# `ed jev status`

Shows whether a TypeSafe key is saved and what the agent knows about it.

```
ed jev status [--probe] [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--probe` | flag | off | List the models and send one tiny decision to confirm the key has credits |
| `--json` | flag | off | Emit JSON on stdout |

Without `--probe` the report comes from memory and costs nothing. The state is
one of `notConfigured`, `ready`, `noCredits`, `keyRejected`, `paused` or
`unreachable`. After a 402 the agent pauses Jev for ten minutes, and after a 401
until the key changes, so a bad key never turns into a stream of failing calls.

## `--json` shape

```json
{
  "configured": true,
  "decisions": 12,
  "key": "ending 4dc2",
  "medianMs": 96,
  "models": ["jev-latest", "jev-preview"],
  "state": "ready"
}
```

`key` and `medianMs` are omitted when unknown, and `message` appears when the
last call failed.

- [`ed jev`](./README.md)
- [All command groups](../README.md)
