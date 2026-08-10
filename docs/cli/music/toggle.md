# `ed music toggle`

Toggles play and pause on the active player. Aliased `playpause`.

```
ed music toggle [--json] [--player <name>]
ed music playpause [--json] [--player <name>]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |
| `--player` | `builtin`, `spotify`, `apple` | whichever is active | Force one player. |

```json
{
  "action": "toggled",
  "name": "Spotify",
  "player": "spotify"
}
```

```
ed music toggle
ed music playpause --player spotify
```

This is the verb to bind to a hotkey: it needs no state of its own and it picks
the player that is playing, which is usually the one you meant.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
