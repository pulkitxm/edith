# `ed clipboard`

`ed clipboard` is the clipboard panel as a command: the history Edith captures,
what it weighs, and the same act of putting an entry back on the pasteboard that
clicking a row performs. Reach for it when you want the thing you copied ten
minutes ago without leaving the terminal, or when a script needs the last thing
that landed on the pasteboard.

The history is a file on disk, `index.jsonl` under
`~/Library/Application Support/Edith/clipboard`, with the bytes behind the
entries in `blobs/` beside it. Nothing here asks the running app for its
answer, so every verb works whether or not Edith is running. Mutations post the
`clipboardChanged` notification afterwards, which is what makes an open panel
redraw; when nothing is listening the post is a no-op and the write still
stands.

Entries are numbered from 1 in the same order the panel shows them: pinned
first, then most recently copied, honouring `clipboardPinTo`. That number is
what `get`, `copy`, `pin`, `unpin` and `rm` take, and it names the same entry
the UI would act on.

## At a glance

| Command | What it does |
| --- | --- |
| `ed clipboard ls` | List the history, pinned first, with each entry's number |
| `ed clipboard stats` | How many entries there are, what they weigh, and the split by family |
| `ed clipboard get <index>` | Print one entry as plain text on stdout |
| `ed clipboard copy <index>` | Put one entry back on the pasteboard and bump it to the top |
| `ed clipboard pin <index>` | Keep one entry at the top and out of the retention sweep |
| `ed clipboard unpin <index>` | Let one entry age out again |
| `ed clipboard rm <index>` | Forget one entry and delete its blob |
| `ed clipboard clear` | Forget the whole history |

A bare `ed clipboard` runs `ls`. `ls` also answers to `list`, and `stats` also
answers to `size`.

## Commands

- [`ed clipboard ls`](./ls.md)
- [`ed clipboard stats`](./stats.md)
- [`ed clipboard get`](./get.md)
- [`ed clipboard copy`](./copy.md)
- [`ed clipboard pin`](./pin.md)
- [`ed clipboard unpin`](./unpin.md)
- [`ed clipboard rm`](./rm.md)
- [`ed clipboard clear`](./clear.md)

## Exit codes

| Code | When this group produces it |
| --- | --- |
| 0 | The command did what it says, including `--help`, an empty `ls`, and pinning something that was already pinned |
| 1 | `get` on an entry that is not text: `error: entry png is not text` |
| 2 | `--limit` below zero, or a command line ArgumentParser cannot parse, such as a non-numeric index or an unknown flag |
| 3 | No entry with that number, or the blob behind an entry is missing |
| 4 | The history is empty and you named a number |

The empty case is the one that surprises people. Every verb that takes a number
goes through the same lookup, and that lookup calls an empty history
unavailable rather than not-found, because the usual reason for it is that the
extension has never been on:

```
$ ed clipboard pin 1
error: the clipboard history is empty
hint: turn the Clipboard extension on with `ed extensions enable clipboard`
```

A number outside a non-empty history is a plain 3, and the hint tells you the
range:

```
$ ed clipboard get 9999
error: there is no clipboard entry 9999
hint: the history holds 1217 entries, numbered from 1
```

A negative limit is caught before anything is read:

```
$ ed clipboard ls --limit=-1
error: --limit cannot be negative
hint: pass 0 or more
```

## Notes and gotchas

- **Numbers are positions, ids are identities.** Any copy, pin, unpin, removal,
  or anything you copy anywhere else on the Mac while the extension is on
  reshuffles the list. A script that acts on more than one entry should read
  `id` from `--json` and re-derive the number, rather than caching a number from
  an earlier run.
- **`copy` reorders, `get` does not.** `copy` bumps `lastCopiedAt` the way
  clicking a row does, so entry 4 becomes entry 1 and everything above it slides
  down. `get` only reads.
- **`kind` means two different things.** In an entry object it is the file
  extension; inside `stats`'s `byKind` it is the family. `family` on an entry
  object is the value that lines up with a `byKind` row.
- **`removed` means two different things.** `rm` reports the index it removed,
  `clear` reports how many it removed. Both sit next to a `remaining` count.
- **Ordering follows the panel, not the file.** Pinned entries come first, each
  group sorted by most recent copy. `ed config set clipboardPinTo bottom` flips
  the two groups, and `ed clipboard ls` follows it, so the same number can name
  a different entry after that setting changes. The command's own help text says
  "newest first", which is only true when nothing is pinned.
- **Mutations take a file lock.** Copy, pin, unpin, remove and clear hold an
  exclusive lock on `~/Library/Application Support/Edith/clipboard/.lock` while
  they rewrite the index, so `ed` and a running Edith cannot interleave writes.
  Reads do not take the lock, so a very long `ls` can race a capture and simply
  show the older list.
- **Removal is permanent.** `rm` and `clear` delete blobs, and neither offers a
  `--yes` gate or a Trash step. There is no `ed clipboard` verb that restores
  anything.
- **The extension does not gate reading.** `ed clipboard ls` reports whatever is
  on disk even with the Clipboard extension off; the extension is what captures
  new entries. `ed extensions enable clipboard` turns capture on, and
  `ed config ls --group clipboard` lists the retention, hotkey, ignore-list and
  capture switches that shape what ends up here.
- **`preview` is a preview.** It is capped at 500 characters, so it is a search
  target and a display string, not the content. Use `get` for the content.
- **Everything works with the app closed.** Nothing in this group waits on
  Edith, and none of it can exit 4 for a missing app. The only 4 it produces is
  the empty history.

## Where to go next

- [`ed color`](../color/README.md), the other history the picker keeps, and the second
  command group defined in the same source file
- [`ed extensions`](../extensions/README.md), to turn clipboard capture on or off
- [`ed config`](../config/README.md), for the `clipboard` group of settings that decide
  what is captured and how long it is kept
- [All command groups](../README.md)
