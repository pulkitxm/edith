# `ed music library`

Chooses the folder Edith uses as its local music library. This is the command
line equivalent of choosing a folder from the Music page.

```
ed music library <path> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `path` | existing local folder | required | Folder to use. A leading `~` expands to your home folder. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "changed": true,
  "external": false,
  "path": "/Users/me/Music"
}
```

```
ed music library ~/Music
ed music library "/Volumes/Media/Music" --json
```

The path is expanded and standardized before it is saved. It must already
exist and be a directory. Selecting a folder clears any stale-library warning,
invalidates cached track metadata, and posts `musicFolderChanged` so a running
Edith window immediately reads the same library. Selecting the current folder
still refreshes live consumers and reports `changed` as `false`.

Folders on `/Volumes` are recorded with the external-path confirmation used by
the Music page. That confirmation prevents a restored but unconfirmed path from
silently sending later commands to Edith's fallback music directory. The raw
`musicFolderPath` preference is intentionally not writable through `ed config`.

A missing path or a path that is a file exits 3 without changing the saved
folder, invalidating caches, or notifying the app.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
