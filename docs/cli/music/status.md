# `ed music status`

Prints one line about whatever is playing, on whichever player. This is the
default subcommand, so `ed music` and `ed np` are the same thing.

```
ed music status [--json] [--player <name>]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |
| `--player` | `builtin`, `spotify`, `apple` | whichever is active | Force one player instead of scoring all three. |

```json
{
  "active": {
    "artist": "Bonobo",
    "durationSeconds": 344,
    "elapsedSeconds": 87.412,
    "isPlaying": true,
    "name": "Spotify",
    "player": "spotify",
    "running": true,
    "title": "Kerala",
    "volume": 0.65
  },
  "player": "spotify",
  "players": [
    {
      "artist": null,
      "durationSeconds": 0,
      "elapsedSeconds": 0,
      "isPlaying": false,
      "name": "Edith",
      "player": "builtin",
      "running": false,
      "title": null,
      "volume": null
    },
    {
      "artist": "Bonobo",
      "durationSeconds": 344,
      "elapsedSeconds": 87.412,
      "isPlaying": true,
      "name": "Spotify",
      "player": "spotify",
      "running": true,
      "title": "Kerala",
      "volume": 0.65
    },
    {
      "artist": null,
      "durationSeconds": 0,
      "elapsedSeconds": 0,
      "isPlaying": false,
      "name": "Apple Music",
      "player": "apple",
      "running": false,
      "title": null,
      "volume": null
    }
  ]
}
```

`players` always holds all three entries in the order `builtin`, `spotify`,
`apple`, even when `--player` narrowed the probe: the ones that were not probed
appear as not running. `active` repeats the winning entry and is `null` when
nothing qualifies. `title` and `artist` are `null` rather than empty strings
when the player has no track, and `volume` is `null` when the player did not
report one.

```
ed music status
ed music status --json
ed music status --player apple
ed np
```

The human line is `<state>  <title>  <artist>  <elapsed>/<duration>
(<player>)`, with state `playing`, `paused` or `idle`, and collapses to
`idle  (Edith)` when there is no track:

```
$ ed music status
playing  Kerala  Bonobo  1:27/5:44  (Spotify)
```

The two output modes fail differently, on purpose. The human form resolves an
active player and exits 4 when there is none, or when the forced one is closed.
`--json` swallows that: it reports `"active": null` and exits 0, so a status
poll never has to be wrapped in an exit-code check.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
