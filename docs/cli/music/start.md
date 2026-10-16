# `ed music start`

Plays one track out of Edith's own library, or everything in a folder. This is
the click on a row in the Music page, so unlike `play` it needs the app running.

```
ed music start <target> [--folder] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `target` | track path or query, or folder path with `--folder` | required | What to play. |
| `--folder` | flag | off | Treat the argument as a folder and play everything under it. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "file": "alpha-song.mp3",
  "path": "alpha-song.mp3",
  "title": "Alpha Song"
}
```

With `--folder` the document is different:

```json
{
  "folder": true,
  "playing": "Chill"
}
```

```
ed music start alpha-song.mp3
ed music start "night drive"
ed music start --folder Chill
```

The check for the menu bar app comes first, before the track is even looked up,
so with Edith closed every form of this exits 4 with `playing from the library
needs the Edith menu bar app to be running`. There is no matching check on the
Music extension: with the extension off the request is posted into the void and
the command still exits 0.

The request is fire and forget. `ed` posts it and reports success without
waiting for the player to confirm, so a zero exit means the message was sent,
not that sound came out. What it posts for a single track is the same `toggle`
the UI posts when you click a row, which means running `ed music start` on the
track that is already playing pauses it rather than restarting it.

`--folder` posts the same `playSource` request the Music page posts when you
play a folder from the UI, with the folder carried under the keys `sourceKind`
and `sourcePath` that the app's handler reads. The queue becomes every track
anywhere under that folder, and playback starts at the head of it, which
`ed music shuffle` reorders.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
