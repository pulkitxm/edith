# `ed music mv`

Moves a track into a folder. Aliased `move`.

```
ed music mv <track> <folder> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `track` | path, or enough of the path or title to be unambiguous | required | The track to move. |
| `folder` | path relative to the library root | required | Where to move it. Pass `""` for the root. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "from": "beta-tune.mp3",
  "to": "Chill/beta-tune.mp3"
}
```

```
ed music mv beta-tune.mp3 Chill
ed music mv "night drive" Focus/Deep
ed music mv Chill/beta-tune.mp3 ""
```

A track is resolved by trying its exact relative path first, then by a
case-insensitive substring match against every track's path and title. A query
that matches more than one exits 3 and lists up to five of them rather than
guessing:

```
$ ed music mv e Chill
error: e matches 2 tracks
hint: beta-tune.mp3, Focus/delta-loop.mp3
```

A query matching nothing exits 3 with `no track matching <query>`. A destination
folder that does not exist exits 3. A file already sitting at the destination,
including the case where the track is already in that folder, exits 1 with
`<path> is already there`; nothing is overwritten.

The file keeps its name across the move. Favourites are repointed at the new
path, and `ed` posts a `renamed` message to the running player so the currently
playing track survives being moved out from under it.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
