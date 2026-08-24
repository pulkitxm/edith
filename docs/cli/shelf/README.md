# `ed shelf`

`ed shelf` reads and writes the notch shelf, the tray of files you park by
dragging them to the notch and pick up again later. Reach for it when a script
should leave a file where the notch will hand it to you, or when you want the
path of something you already dropped there without opening the shelf at all.

The shelf is a plain folder with an index beside it: the files sit flat in
`~/Library/Application Support/Edith/Shelf`, and `.index.json` in that same
folder records each one's id, name, canvas position and when it landed. File,
text, position and removal mutations work without Edith running. `share` asks
the running menu bar helper to present its anchored macOS picker.

Items are numbered from 1, newest first by the time they were added. That
number is what `path`, `update`, `rm`, `open`, `reveal` and `share` take. It is
`ed`'s own ordering: the notch lays
its tiles out on a canvas you can drag them around on, so the number here names
a row in this listing rather than a position on screen.

## At a glance

| Command | What it does |
| --- | --- |
| `ed shelf` | Runs `ed shelf ls`, which is the default subcommand. |
| `ed shelf ls` | Lists what is parked, newest first, with size and when it landed. |
| `ed shelf path <n>` | Prints the full path of one item, which is what to pipe into another tool. |
| `ed shelf add <file>` | Copies a file onto the shelf and leaves the original where it is. |
| `ed shelf add-text <text...>` | Writes text into a new shelf item. |
| `ed shelf update <n> --x <number> --y <number>` | Sets one item's stored canvas position. |
| `ed shelf rm <n...>` | Previews deleting selected shelf copies; `--yes` applies it. |
| `ed shelf clear` | Previews emptying the shelf; `--yes` applies it. |
| `ed shelf purge [window]` | Previews removing items older than the configured or named window. |
| `ed shelf open <n...>` | Opens selected items in their default applications. |
| `ed shelf reveal <n...>` | Reveals selected items in Finder. |
| `ed shelf share <n...>` | Opens the notch shelf's macOS share picker for selected items. |

`ed shelf list` is the same command as `ed shelf ls`, and `ed shelf` with
nothing after it runs `ls`, including its flags: `ed shelf --json` is
`ed shelf ls --json`.

## Commands

- [`ed shelf ls`](./ls.md)
- [`ed shelf path`](./path.md)
- [`ed shelf add`](./add.md)
- [`ed shelf add-text`](./add-text.md)
- [`ed shelf update`](./update.md)
- [`ed shelf rm`](./rm.md)
- [`ed shelf clear`](./clear.md)
- [`ed shelf purge`](./purge.md)
- [`ed shelf open`](./open.md)
- [`ed shelf reveal`](./reveal.md)
- [`ed shelf share`](./share.md)

## Exit codes

| Code | When this group produces it |
| --- | --- |
| 0 | The read, mutation or action request succeeded. Also an empty shelf under `ls`, a preview, and `--help` on the group or any verb. |
| 1 | A file or index mutation failed. The hint is the system's own description. |
| 2 | The command line was wrong in ArgumentParser's own terms: an unknown flag, a missing `<index>` or `<file>`, an `<index>` that is not an integer, or an extra positional argument. |
| 3 | `add` was given a path with nothing at it, or an item command was given a number below 1 or above the number of items. |
| 4 | An item command was run on an empty shelf, or `share` could not reach an enabled running notch shelf. |

For local index operations, exit 4 means the shelf is empty. For `share`, it
means the menu bar helper is not running, the Notch Shelf extension is off, the
items disappeared before the helper handled them, or no shelf panel could
present the picker. `ls` treats an empty shelf as success, so use it when
probing state.

## Notes and gotchas

- The shelf folder is flat. Every item is a direct child of
  `~/Library/Application Support/Edith/Shelf`, and the index is `.index.json`
  in that same folder, hidden by its leading dot. Because names are made
  unique against the folder, adding a file called `.index.json` lands as
  `.index 2.json` rather than clobbering the index.
- The CLI and notch helper use one mutation executor and broadcast each saved
  snapshot. Changes made by `ed` appear in a running shelf, and the next UI
  action starts from the same index instead of restoring a stale in-memory list.
- `ls` sorts newest first every time, but the index file is written in whatever
  order the writer used. `add` appends, the way the app does. A confirmed `rm`
  filters the current index by the previewed id, preserving the stored order of
  everything else.
- Each item can carry a `position` recorded by dragging its tile around the
  notch canvas. `ls`, `path`, add results and action results return it as either
  `{ "x": number, "y": number }` or `null`. `update` writes the same shared
  field as a native canvas drag.
- `add` and `add-text` report the new item's index from the snapshot that was
  committed. The number therefore matches the next `ls` result even when an
  existing item carries a timestamp from the future.
- There is no `ed shelf get`, no `ed shelf copy` and no way to pull an item
  back out. `path` plus `cp` is the whole story, and the shelf's copy stays
  until you remove it.
- Nothing here is gated on the extension. `ed shelf` works with
  `notchShelfEnabled` off, so you can park and read files even when the notch
  is not showing anything. Turn the surface on with
  `ed extensions enable notchShelf`.
- `purge` uses `notchShelfKeepDuration` unless you name `forever`, `oneHour`,
  `oneDay`, `oneWeek` or `oneMonth`. It previews exact file paths by default
  and removes them only with `--yes`. The running shelf uses the same expiry
  executor when it starts and expands.
- The rest of the notch's behaviour is settings rather than commands:
  `notchShelfOpenOnDrag`, `notchShelfOpenOnHover`, `notchShelfRequireOption`,
  `notchShelfRemoveAfterDragOut`, `notchShelfShowOnExternal`,
  `notchShelfHaptics` and `notchShelfShowMusic`. See `ed config ls notchShelf`.
- The table flattens control characters out of a name, so a filename
  containing a newline or a tab prints on one line. `--json` carries the name
  exactly as it is on disk, which is what to match on.
- `--help` works on the group and every verb, prints on stdout and exits
  0. `--version` is inherited from the root and works on any of them too,
  printing the CLI version.
- Completion knows the group and reads the current shelf indices. `ed shelf <TAB>`
  offers the verbs, `ed shelf add <TAB>` completes file paths, and every item
  slot offers the current item numbers, including repeated grouped selections.

## Where to go next

- [`ed clipboard`](../clipboard/README.md), the other thing the notch panel holds, and
  the one whose entries are numbered the same way.
- [`ed extensions`](../extensions/README.md), to turn the notch shelf itself on or off.
- [`ed config`](../config/README.md), for the shelf's hover, drag and expiry settings.
- [Conventions and contracts](../conventions.md), for the exit code table and
  the `--json` guarantee in full.
- [All `ed` commands](../README.md).
