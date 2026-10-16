# `ed music pause`

Pauses the active player.

```
ed music pause [--json] [--player <name>]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |
| `--player` | `builtin`, `spotify`, `apple` | whichever is active | Force one player. |

```json
{
  "action": "paused",
  "name": "Edith",
  "player": "builtin"
}
```

```
ed music pause
ed music pause --player spotify
```

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
