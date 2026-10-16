# `ed music next`

Skips to the next track.

```
ed music next [--json] [--player <name>]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |
| `--player` | `builtin`, `spotify`, `apple` | whichever is active | Force one player. |

```json
{
  "action": "skipped",
  "name": "Spotify",
  "player": "spotify"
}
```

```
ed music next
ed music next --player builtin
```

On the built-in player the next track comes from the current queue, which
`ed music shuffle` reorders.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
