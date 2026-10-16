# `ed music stop`

Stops the active player and resets its position to the start of the track.

```
ed music stop [--json] [--player <name>]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |
| `--player` | `builtin`, `spotify`, `apple` | whichever is active | Force one player. |

```json
{
  "action": "stopped",
  "name": "Apple Music",
  "player": "apple"
}
```

```
ed music stop
ed music stop --player apple
```

Apple Music has a real `stop` verb and gets it. Spotify and the built-in player
do not, so `stop` there is a pause followed by a seek back to zero: two verbs in
one AppleScript for Spotify, and two posted commands for the built-in player.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
