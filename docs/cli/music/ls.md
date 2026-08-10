# `ed music ls`

Lists Edith's library one folder at a time. Aliased `list`.

```
ed music ls [folder] [--folders] [--recursive] [--search <text>] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `folder` | path relative to the library root | `""`, the root | Folder to list. |
| `--folders` | flag | off | Only folders. Tracks are left out of the table, and the JSON `tracks` array comes back empty. |
| `--recursive` | flag | off | Every track underneath, not just the ones directly in this folder. |
| `--search` | text | none | Only tracks whose relative path or title contains this text, case-insensitively. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "folder": "Focus",
  "folders": [
    {
      "name": "Deep",
      "path": "Focus/Deep",
      "tracks": 12
    }
  ],
  "tracks": [
    {
      "file": "delta-loop.mp3",
      "path": "Focus/delta-loop.mp3",
      "title": "Delta Loop"
    }
  ]
}
```

```
ed music ls
ed music ls Focus
ed music ls --recursive --search drive
ed music ls --folders --json
```

The library is a folder of files, so this reads the disk and does not need Edith
running. Only playable files are counted: `mp3`, `m4a`, `m4b`, `aac`, `wav`,
`aiff`, `flac`, `mp4` and `mov`. Hidden files are skipped, and a recursive walk
does not descend into packages. A title is derived from the file name rather
than from tags: the extension is dropped, dashes and underscores become spaces,
and the result is capitalised, so `alpha-song.mp3` lists as `Alpha Song`.

Subfolders are always listed, whatever `--search` or `--recursive` say, and each
one carries the number of playable tracks anywhere underneath it. `--search`
filters tracks only. Folders sort by name and tracks by file name, both the way
Finder sorts; `--recursive` sorts by relative path instead.

```
$ ed music ls
FOLDER  TRACKS
Chill   4
Focus   12

TITLE       PATH
Alpha Song  alpha-song.mp3
Beta Tune   beta-tune.mp3
```

An empty folder prints `nothing here` on stderr and nothing on stdout. A folder
that does not exist exits 3; with no music folder configured at all, this and
every other library command exit 4 and say where to set one.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
