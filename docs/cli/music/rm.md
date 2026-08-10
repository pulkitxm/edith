# `ed music rm`

Moves a track or a folder to the Trash. Nothing is deleted outright, so a
mistake is recoverable from Finder.

```
ed music rm <target> [--folder] [--yes] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `target` | track path or query, or folder path with `--folder` | required | What to trash. |
| `--folder` | flag | off | Remove a folder and everything in it. |
| `--yes` | flag | off | Actually do it. Without this nothing is moved. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "path": "Chill/beta-tune.mp3",
  "tracks": 1,
  "trashed": true
}
```

```
ed music rm beta-tune.mp3
ed music rm beta-tune.mp3 --yes
ed music rm --folder Chill --yes
ed music rm --folder Chill --json
```

Without `--yes` this is a dry run that touches nothing, prints what it would do,
and still exits 0. The JSON is the same document with `"trashed": false`, which
is the field to gate on:

```
$ ed music rm --folder Chill
would move Chill to the Trash (4 track(s))
nothing was moved; pass --yes to go ahead
```

`tracks` is 1 for a track and the number of playable tracks anywhere under the
folder for `--folder`. Trashing the library root itself is refused and exits 1
with `the library root cannot be removed`. A Trash operation the filesystem
rejects, for instance on a volume with no Trash, exits 1 with what macOS said.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
