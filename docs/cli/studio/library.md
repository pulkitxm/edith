# `ed studio library`

[Back to `ed studio`](./README.md)

Manage the media references shown in Studio's **Files** tab. Commands run headlessly,
save to this CLI's scoped preferences and refresh an already running matching app.
`ed studio library` defaults to `list`.

| Command | What it does |
| --- | --- |
| `ed studio library list [--json]` | Lists saved references, including missing files. |
| `ed studio library add <paths...> [--json]` | Adds files or recursively expands folders, skipping duplicate paths. |
| `ed studio library remove <paths...> [--json]` | Removes references, including paths that no longer exist. |
| `ed studio library clear [--recent] [--json]` | Clears the media list and optionally recent tool-run history. |

JSON output is an array of `path`, `name`, ISO-8601 `addedAt` and `exists` records.
Add and remove return the updated list. Clear returns an empty array.
Aliases are `list`/`ls` and `remove`/`rm`.

Removing or clearing references preserves originals, generated outputs and saved
video projects. Recent history is separate from projects. Use
[`ed studio edit trash <project>`](./edit.md#move-a-project-to-trash) to remove a
project document reversibly. Development builds use their bundled CLI and isolated
preferences, media list and notification namespace.

The running Studio model observes library notifications and preference-file changes.
Its next add or remove reads the current saved list, so a stale window cannot
reintroduce references that a CLI command cleared.

[All `ed` commands](../README.md)
