# `ed music previous`

Goes back to the previous track. Aliased `prev`.

```
ed music previous [--json] [--player <name>]
ed music prev [--json] [--player <name>]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |
| `--player` | `builtin`, `spotify`, `apple` | whichever is active | Force one player. |

```json
{
  "action": "went back",
  "name": "Apple Music",
  "player": "apple"
}
```

```
ed music previous
ed music prev
```

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
