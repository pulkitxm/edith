# `ed music play`

Resumes playback on the active player. It resumes what is loaded rather than
choosing something to play; `ed music start` is the one that picks a track.

```
ed music play [--json] [--player <name>]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |
| `--player` | `builtin`, `spotify`, `apple` | whichever is active | Force one player. |

```json
{
  "action": "playing",
  "name": "Spotify",
  "player": "spotify"
}
```

```
ed music play
ed music play --player builtin
ed music play --json
```

`action` is the past tense the human line prints, so stdout reads
`playing  (Spotify)`. On Spotify and Apple Music this sends the AppleScript
`play`; on the built-in player it posts the `resume` command, which the app acts
on only when a track is loaded and paused.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
