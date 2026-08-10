# `ed extensions ls`

Prints every registry entry and whether it is on.

```
ed extensions ls [--json]
```

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the table |

The human form is a four column table, padded with two spaces, in registry
order:

```
$ ed extensions ls
ID           STATE  GROUP      NAME
usage        on     Agent      Agent Usage
system       on     System     System
machines     on     System     Machines
systemStats  off    System     CPU & Memory in menu bar
micMute      off    System     Mic Mute
music        off    Media      Music
calendar     off    Media      Calendar
notchShelf   off    Media      Notch Shelf
clipboard    on     Utilities  Clipboard
focusDim     off    Utilities  Focus Dim
presenter    off    Utilities  Presenter
colorPicker  on     Utilities  Color Picker
```

`--json` is a top-level array of one object per registry entry, in the same
order, and every row carries the same eleven keys whether or not they have
anything in them. A test asserts exactly that set of keys on every row. The
first two rows:

```json
[
  {
    "enabled": true,
    "featured": true,
    "group": "Agent",
    "id": "usage",
    "key": "tabUsageEnabled",
    "missingRequiredPermissions": [],
    "optionalPermissions": [
      "notifications"
    ],
    "requiredPermissions": [],
    "requiredTools": [
      "claude",
      "codex"
    ],
    "summary": "Claude and Codex limits, usage stats, and alerts.",
    "title": "Agent Usage"
  },
  {
    "enabled": true,
    "featured": true,
    "group": "System",
    "id": "system",
    "key": "tabSystemEnabled",
    "missingRequiredPermissions": [],
    "optionalPermissions": [
      "accessibility",
      "inputMonitoring"
    ],
    "requiredPermissions": [],
    "requiredTools": [],
    "summary": "Running apps, prevent sleep, and the keyboard-cleaning lock.",
    "title": "System"
  }
]
```

`group` is the readable group name, capitalised: `Agent`, `System`, `Media` or
`Utilities`. `key` is the preference `ed config` uses for the same feature.
`missingRequiredPermissions` is `requiredPermissions` filtered down to the ones
Edith's mirrored grant state does not say yes to, so it is the field to gate on
rather than parsing prose.

```
ed extensions ls
ed extensions list
ed extensions ls --json
ed extensions ls --json | jq -r '.[] | select(.enabled) | .id'
```

`ls` reads preferences and nothing else. It never fails and always exits 0, and
it is the default subcommand, so bare `ed extensions` prints the same table.

## Where to go next

- [`ed extensions`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
