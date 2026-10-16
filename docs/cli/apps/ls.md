# `ed apps ls`

Prints the applications running on this Mac. It is the default subcommand, so
`ed apps` on its own runs it, and `list` is an accepted alias.

```
ed apps ls [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the table. Long form only, there is no `-j`. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |
| `--version` | flag | off | Print the CLI version on stdout and exit 0. Inherited from the root command, so it works here too. |

There is nothing else. `ls` has no search, no limit and no sort option: it
prints every app it can see, in one order, every time.

The table is five columns, and the rows are sorted by name with a
case-insensitive, locale-aware comparison:

```
$ ed apps ls
NAME     PID    CPU   MEMORY    BUNDLE
Dia      40466  1.2%  342.5 MB  company.thebrowser.dia
Finder   612    0.4%  198.8 MB  com.apple.finder
Spotify  18719  0.0%  284.2 MB  com.spotify.client
```

The list is `NSWorkspace`'s running applications filtered to the ones whose
activation policy is regular, which means the ones macOS gives a Dock icon and
a menu bar to. Background daemons, launch agents and menu bar only apps are not
in it, and neither is Edith's own menu bar helper, so the `Edith` row above is
the main window process and never the helper that actually does the quitting.
An app whose windows are all closed but which is still in the Dock is listed,
despite the command's own one-line summary calling these the apps with a window
open.

## `--json` shape

A top-level array, in the same order as the table, of one object per app. This
is a real document trimmed to three of the eight entries:

```json
[
  {
    "active": true,
    "bundleID": "company.thebrowser.dia",
    "cpuPercent": 1.2,
    "memoryMB": 342.5,
    "name": "Dia",
    "pid": 40466
  },
  {
    "active": false,
    "bundleID": "com.apple.finder",
    "cpuPercent": 0.4,
    "memoryMB": 198.8,
    "name": "Finder",
    "pid": 612
  },
  {
    "active": false,
    "bundleID": "dev.zed.Zed",
    "cpuPercent": 0,
    "memoryMB": 121.6,
    "name": "Zed",
    "pid": 49161
  }
]
```

What the fields mean:

- `name` is the app's localized name, the same string the Dock and the Finder
  show. An app that reports no name gets `"Unknown"`, so the key is always a
  string.
- `bundleID` is the bundle identifier, and it is `null` rather than missing when
  the process has none. It is the only nullable field here.
- `pid` is the process id as an integer, which is what the helper is handed when
  you quit a single app.
- `active` is true for the frontmost app and false for every other, so exactly
  one entry is true while any app is focused and none is while focus sits with
  something the list does not cover.
- `cpuPercent` is the process CPU consumed across a 100 millisecond sample.
  Values can exceed 100 on a process using more than one core.
- `memoryMB` is the physical footprint in mebibytes at the end of the sample.
- The `BUNDLE` column is `bundleID`, printed as an empty cell where JSON says
  `null`. The table has no column for `active`.

Object keys are sorted, so `active`, `bundleID`, `cpuPercent`, `memoryMB`, `name`
and `pid` always come in that order. The array keeps the name order.

## Examples

```
ed apps ls
ed apps ls --json
ed apps ls --json | jq -r '.[] | select(.active) | .name'
ed apps ls --json | jq -r '.[] | "\(.pid) \(.name)"'
```

## Behaviour notes

Nothing is mutated and nothing is written. Neither Edith process has to be
running, no macOS permission is involved, and no subprocess is launched. The
command takes one short local resource sample and never exits 4.

Every cell is flattened before it is printed: newlines, carriage returns and
tabs become spaces, and other control characters are dropped, so a hostile app
name cannot break the table across lines. Column widths are counted in
characters, which means a name carrying an invisible mark such as a
left-to-right override still occupies a column of width the eye does not see,
and its row can look a character out of line.

`ed apps ls` and the app's Running apps card use the same EdithKit discovery and
resource measurement operations. The card keeps sampling and sorts by CPU
descending by default. The command takes one sample and sorts by name. For all
processes, including those without a Dock icon, use `ed system stats --processes <n>`.

## Where to go next

- [`ed apps`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
