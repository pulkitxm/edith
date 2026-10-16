# `ed music volume`

Sets the active player's volume as a fraction from 0 to 1.

```
ed music volume <level> [--json] [--player <name>]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `level` | number from 0 to 1 | required | The volume to set, as a fraction. |
| `--json` | flag | off | Emit JSON on stdout. |
| `--player` | `builtin`, `spotify`, `apple` | whichever is active | Force one player. |

```json
{
  "action": "volume set",
  "name": "Spotify",
  "player": "spotify"
}
```

```
ed music volume 0.4
ed music volume 1 --player spotify
ed music volume 0.25 --json
```

The level is checked before anything is sent: outside 0 to 1 exits 2 with
`volume must be between 0 and 1`, and a value that is not a number exits 2 as a
parse failure. Spotify and Apple Music take a percentage, so the fraction is
multiplied by 100 and rounded on the way out and divided by 100 on the way back
in `status`. The JSON reports only what was done and to whom; read the level
back with `ed music status --json`.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
