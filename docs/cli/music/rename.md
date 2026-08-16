# `ed music rename`

Renames a track or a folder in place.

```
ed music rename <target> <name> [--folder] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `target` | track path or query, or folder path with `--folder` | required | What to rename. |
| `name` | text | required | The new name, without the extension. |
| `--folder` | flag | off | Rename a folder rather than a track. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "from": "alpha-song.mp3",
  "to": "Night Drive.mp3"
}
```

```
ed music rename alpha-song.mp3 "Night Drive"
ed music rename "beta tune" Interlude
ed music rename --folder Chill Calm
```

A track keeps its extension, so renaming `alpha-song.mp3` to `Night Drive` gives
`Night Drive.mp3`. A folder has no extension to keep and takes the name as
given. The name is sanitised the same way `mkdir` sanitises it, a blank name
exits 1, and renaming onto a name that already exists exits 1 rather than
overwriting.

Without `--folder` the target goes through the same track resolution `mv` uses,
so an ambiguous query exits 3 with the matches. With `--folder` the target has
to be a real folder path and anything else exits 3. Favourites follow the new
name, folders included, and the running player is told so playback does not
break mid-track.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
