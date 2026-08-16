# `ed music players`

Lists every player Edith can see, what state each is in, and which one the other
commands would target.

```
ed music players [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "active": {
    "artist": null,
    "durationSeconds": 212,
    "elapsedSeconds": 41,
    "isPlaying": true,
    "name": "Edith",
    "player": "builtin",
    "running": true,
    "title": "alpha-song.mp3",
    "volume": 0.7
  },
  "player": "builtin",
  "players": [
    {
      "artist": null,
      "durationSeconds": 212,
      "elapsedSeconds": 41,
      "isPlaying": true,
      "name": "Edith",
      "player": "builtin",
      "running": true,
      "title": "alpha-song.mp3",
      "volume": 0.7
    },
    {
      "artist": null,
      "durationSeconds": 0,
      "elapsedSeconds": 0,
      "isPlaying": false,
      "name": "Spotify",
      "player": "spotify",
      "running": false,
      "title": null,
      "volume": null
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

The document is the same shape `ed music status --json` emits. This command has
no `--player`, because listing one player is not a list, and it never fails for
want of a running player:

```
$ ed music players
PLAYER   STATE    PLAYBACK          TRACK
builtin  -        -
spotify  running  playing   active  Kerala
apple    -        -
```

The fourth column has no heading and holds `active` on exactly one row, or on no
row at all when nothing is running. The built-in player reports its track as a
file name rather than a title, because that is what the app broadcasts.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
