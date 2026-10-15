# `ed color ls`

Lists the colours in the picker's history, newest first.

Usage:

```
ed color ls [--format <f>] [--limit <n>] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--format <f>` | one of `hex`, `rgb`, `hsl`, `swiftUI`, `nsColor` | unset, which prints the table | Prints that one representation per colour, one per line, and nothing else. |
| `--limit <n>` | integer, 0 or more | `25` | Shows at most this many colours. `0` shows all of them. |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments.

`--format` is matched against the raw format names exactly, so `swiftUI` is
accepted and `SwiftUI`, `swiftui` and `hexadecimal` are not; an unknown name
exits 3 and lists the five it accepts. `--limit` is checked before the format
name and before the store is read, so a negative value exits 2 with
`--limit cannot be negative` on stderr and nothing on stdout. `--limit 0` is not
unbounded in practice: the app caps what it stores at `colorPickerHistorySize`,
which is clamped to 1 through 100.

`--json` shape, an array with one object per colour:

```json
[
  {
    "hex": "#4C6EF5",
    "hsl": "hsl(228, 89%, 63%)",
    "pickedAt": "2026-08-07T18:41:09Z",
    "profile": "sRGB",
    "rgb": "rgb(76, 110, 245)"
  },
  {
    "hex": "#1B1B1E",
    "hsl": "hsl(240, 5%, 11%)",
    "pickedAt": "2026-08-06T21:04:33Z",
    "profile": "displayP3",
    "rgb": "rgb(27, 27, 30)"
  }
]
```

`profile` is the raw value, `sRGB` or `displayP3`, not the display name the
table prints. `pickedAt` is ISO 8601 in UTC. The JSON carries `hex`, `rgb` and
`hsl` only: `swiftUI` and `nsColor` are reachable through `--format`, and the
swatch's id and its raw components are not exposed at all. An empty history is
an empty array rather than an error.

Examples:

```
ed color ls
ed color ls --format hex --limit 1
ed color ls --limit 0 --format swiftUI
ed color ls --json
```

The table is four columns: hex, `rgb()`, the colour space under its display
name, and when it was picked.

```
$ ed color ls
HEX      RGB                PROFILE     PICKED
#4C6EF5  rgb(76, 110, 245)  sRGB        2026-08-07T18:41:09Z
#F9C442  rgb(249, 196, 66)  sRGB        2026-08-07T18:39:52Z
#1B1B1E  rgb(27, 27, 30)    Display P3  2026-08-06T21:04:33Z
```

`--format` replaces the table with bare values, which is what makes the command
worth piping. The newest colour is the first line, so `--limit 1` is the colour
you just picked:

```
$ ed color ls --format hex --limit 1
#4C6EF5

$ ed color ls --format swiftUI --limit 2
Color(red: 0.2980, green: 0.4310, blue: 0.9610)
Color(red: 0.9760, green: 0.7690, blue: 0.2590)
```

A name that is not one of the five formats exits 3 with the list, rather than
being guessed at:

```
$ ed color ls --format SwiftUI
error: no colour format named SwiftUI
hint: formats: hex, rgb, hsl, swiftUI, nsColor
```

Behaviour: `ls` only reads and writes nothing back, needs neither the main app
nor the menu bar helper, and never fails because Edith is closed. With an empty history
and no `--format` it writes `no colours picked yet` to stderr, leaves stdout
empty and exits 0. With `--format` and an empty history it prints nothing at
all, not even that note, so a caller can treat empty output as "no colours"
without parsing prose. Unlike `ed clipboard ls`, a list cut short by `--limit`
says nothing about it, so a default run stops at 25 silently.

## Where to go next

- [`ed color`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
