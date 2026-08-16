# `ed shelf`

`ed shelf` reads and writes the notch shelf, the tray of files you park by
dragging them to the notch and pick up again later. Reach for it when a script
should leave a file where the notch will hand it to you, or when you want the
path of something you already dropped there without opening the shelf at all.

The shelf is a plain folder with an index beside it: the files sit flat in
`~/Library/Application Support/Edith/Shelf`, and `.index.json` in that same
folder records each one's id, name and when it landed. Nothing here talks to
the app, so every verb works whether or not Edith is running, and the paths it
prints are real paths any other tool can open.

Items are numbered from 1, newest first by the time they were added. That
number is what `path` and `rm` take. It is `ed`'s own ordering: the notch lays
its tiles out on a canvas you can drag them around on, so the number here names
a row in this listing rather than a position on screen.

## At a glance

| Command | What it does |
| --- | --- |
| `ed shelf` | Runs `ed shelf ls`, which is the default subcommand. |
| `ed shelf ls` | Lists what is parked, newest first, with size and when it landed. |
| `ed shelf path <n>` | Prints the full path of one item, which is what to pipe into another tool. |
| `ed shelf add <file>` | Copies a file onto the shelf and leaves the original where it is. |
| `ed shelf rm <n>` | Takes one item off the shelf and deletes the shelf's copy. |
| `ed shelf clear` | Empties the shelf. |

`ed shelf list` is the same command as `ed shelf ls`, and `ed shelf` with
nothing after it runs `ls`, including its flags: `ed shelf --json` is
`ed shelf ls --json`.

## Commands

- [`ed shelf ls`](./ls.md)
- [`ed shelf path`](./path.md)
- [`ed shelf add`](./add.md)
- [`ed shelf rm`](./rm.md)
- [`ed shelf clear`](./clear.md)

## Exit codes

| Code | When this group produces it |
| --- | --- |
| 0 | The listing, path, add, removal or clear succeeded. Also an empty shelf under `ls`, an already empty shelf under `clear`, and `--help` on the group or any verb. |
| 1 | `add` could not copy the file: an unreadable source, a destination the filesystem refused, or no space. The hint is the system's own description. |
| 2 | The command line was wrong in ArgumentParser's own terms: an unknown flag, a missing `<index>` or `<file>`, an `<index>` that is not an integer, or an extra positional argument. |
| 3 | `add` was given a path with nothing at it, or `path` or `rm` was given a number below 1 or above the number of items. |
| 4 | `path` or `rm` was run on an empty shelf. |

Exit 4 here does not mean the app is missing. Nothing in this group talks to
Edith, and the one thing that reports itself unavailable is an empty shelf,
which is a state you fix with `ed shelf add` rather than by starting the app.
`ls` treats the same empty shelf as success, so use `ls` when you are probing
rather than acting.

## Notes and gotchas

- The shelf folder is flat. Every item is a direct child of
  `~/Library/Application Support/Edith/Shelf`, and the index is `.index.json`
  in that same folder, hidden by its leading dot. Because names are made
  unique against the folder, adding a file called `.index.json` lands as
  `.index 2.json` rather than clobbering the index.
- A running Edith holds the index in memory. It reads `.index.json` once, when
  the notch shelf starts, and writes the whole in-memory list back on every
  change it makes. Nothing tells it that `ed` wrote the file, so a shelf
  changed from the CLI while the app is open does not appear in the notch, and
  the next drag or drag-out from the notch saves the app's older list over
  yours. Files added by `ed` survive as orphans in the folder; items removed by
  `ed` come back in the index with `"exists": false`, because their copies are
  really gone. Quitting and reopening Edith, or running the CLI while it is
  closed, avoids the whole question.
- `ls` sorts newest first every time, but the index file is written in whatever
  order the writer used. `add` appends, the way the app does. `rm` writes back
  what it read, which is the sorted list, so removing one item quietly reverses
  the stored order of the rest. That changes nothing about what `ed` prints,
  and it does move the tiles in the notch for items you have never dragged,
  because an untouched tile is positioned by its index in the file.
- Each item can carry a `position` recorded by dragging its tile around the
  notch canvas. `ed` never reads it, writes it or shows it, and it survives
  `ed shelf rm` for the items that are left, because `rm` saves back the items
  it decoded rather than rebuilding them.
- `add` always reports `"index": 1`. The number is written into the document
  rather than recomputed, and it is right because the item's `addedAt` is the
  moment you ran the command, unless something on the shelf carries a
  timestamp from the future.
- There is no `ed shelf get`, no `ed shelf copy` and no way to pull an item
  back out. `path` plus `cp` is the whole story, and the shelf's copy stays
  until you remove it.
- Nothing here is gated on the extension. `ed shelf` works with
  `notchShelfEnabled` off, so you can park and read files even when the notch
  is not showing anything. Turn the surface on with
  `ed extensions enable notchShelf`.
- Nothing here expires anything either. Items expire only when a running Edith
  sweeps them, using `notchShelfKeepDuration`, whose values are `forever`,
  `oneHour`, `oneDay`, `oneWeek` and `oneMonth`, defaulting to `forever` when
  the setting is unset or unrecognised. The sweep happens when the shelf starts
  and each time it expands, so a Mac whose Edith is closed keeps everything
  regardless of the setting.
- The rest of the notch's behaviour is settings rather than commands:
  `notchShelfOpenOnDrag`, `notchShelfOpenOnHover`, `notchShelfRequireOption`,
  `notchShelfRemoveAfterDragOut`, `notchShelfShowOnExternal`,
  `notchShelfHaptics` and `notchShelfShowMusic`. See `ed config ls notchShelf`.
- The table flattens control characters out of a name, so a filename
  containing a newline or a tab prints on one line. `--json` carries the name
  exactly as it is on disk, which is what to match on.
- `--help` works on the group and on all five verbs, prints on stdout and exits
  0. `--version` is inherited from the root and works on any of them too,
  printing the CLI version.
- Completion knows the group: `ed shelf <TAB>` offers the five verbs, and
  `ed shelf add <TAB>` completes file paths. The index slots of `path` and `rm`
  offer nothing, because completion does not read the shelf; run
  `ed shelf ls` for the numbers.

## Where to go next

- [`ed clipboard`](../clipboard/README.md), the other thing the notch panel holds, and
  the one whose entries are numbered the same way.
- [`ed extensions`](../extensions/README.md), to turn the notch shelf itself on or off.
- [`ed config`](../config/README.md), for the shelf's hover, drag and expiry settings.
- [Conventions and contracts](../conventions.md), for the exit code table and
  the `--json` guarantee in full.
- [All `ed` commands](../README.md).
