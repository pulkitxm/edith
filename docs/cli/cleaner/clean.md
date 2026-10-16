# `ed cleaner clean`

Moves what a scan finds to the Trash. This is the destructive verb.

Usage:

```
ed cleaner clean [--category <c>] [--root <dir>]... [--yes] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--category <c>` | one of the nineteen ids, matched exactly | unset, which means every category | Restricts the clean to that one category. |
| `--root <dir>` | a path to an existing directory, repeatable | none | Also sweeps this folder for project junk, and trashes what it finds there. |
| `--yes` | flag | off | Actually moves the files. Without it nothing is touched. |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments. `--category` and `--root` mean exactly what
they mean on `scan`, and produce the same errors.

`--json` shape, without `--yes`:

```json
{
  "applied": false,
  "items": 2,
  "reclaimedBytes": 0,
  "wouldReclaimBytes": 2273554432
}
```

and with it:

```json
{
  "applied": true,
  "items": 2,
  "reclaimedBytes": 2273554432,
  "wouldReclaimBytes": 2273554432
}
```

The shape is the same either way, which is what makes it safe to gate on:
`applied` says whether anything moved, `items` is how many paths the scan
matched, `wouldReclaimBytes` is their total size, and `reclaimedBytes` counts
only the ones `trashItem` actually accepted. `reclaimedBytes` smaller than
`wouldReclaimBytes` means some paths could not be trashed. There is no
per-category or per-path breakdown in the result, so read `scan --json` first
if you want to know what is about to go.

Examples:

```
ed cleaner clean
ed cleaner clean --category npm --yes
ed cleaner clean --root ~/code --category nodeModules --yes
ed cleaner clean --json
```

A bare run is a dry run. The count lands on stdout and the nudge on stderr:

```
$ ed cleaner clean --category npm
would move 2 items, 2.3 GB, to the Trash
pass --yes to do it
```

```
$ ed cleaner clean --category npm --yes
moved 2.3 GB to the Trash
```

Behaviour: `clean` runs its own scan first and never reuses the result of an
earlier `ed cleaner scan`, so a `scan` then `clean` pair walks the disk twice
and can legitimately disagree if something changed in between. It then trashes
**every** item that scan produced. There is no selection: the Cleaner card's
ticked rows, its per-item overrides and the `onByDefault` flag are all ignored,
so a bare `ed cleaner clean --yes` takes the Playwright browsers and the
Puppeteer Chromium builds that the card leaves unticked. Narrow it with
`--category` when that is not what you want.

`clean` shows the same spinner line as `scan` on stderr, and under the same
rules, while it does its own walk. With `--yes` a second phase follows it,
`moving <n> items to the Trash`, for as long as `trashItem` is working through
the list; a dry run stops after the scan phase. Both lines erase themselves, so
the counts on stdout are all that survives the run.

A path that cannot be trashed is skipped silently: it is left in place, its
bytes are not counted in `reclaimedBytes`, and the command still exits 0. A run
that trashes nothing at all prints `moved 0 B to the Trash` and also exits 0,
so the exit code tells you the command ran, not that space was freed. Compare
`reclaimedBytes` against `wouldReclaimBytes` for that.

Nothing is deleted in place. Items go to the Trash, which means the disk is not
actually any emptier until you empty it, and it also means an accidental
`ed cleaner clean --yes` is recoverable from Finder.

## Where to go next

- [`ed cleaner`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
