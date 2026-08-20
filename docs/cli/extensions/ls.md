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
herdr        off    Agent      Herdr
system       on     System     System
machines     on     System     Machines
companion    off    Agent      Companion
systemStats  off    System     CPU & Memory in menu bar
micMute      off    System     Mic Mute
lidAwake     off    System     Lid Awake
music        off    Media      Music
calendar     off    Media      Calendar
notchShelf   off    Media      Notch Shelf
clipboard    on     Utilities  Clipboard
focusDim     off    Utilities  Focus Dim
presenter    off    Utilities  Presenter
colorPicker  on     Utilities  Color Picker
```

`--json` is a top-level array of one object per registry entry, in the same
order, and every row carries the same thirteen keys whether or not they have
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
    "optionalCapabilities": [
      "notifications"
    ],
    "optionalPermissions": [
      "notifications"
    ],
    "requiredCapabilities": [
      "usageCollection"
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
    "enabled": false,
    "featured": true,
    "group": "Agent",
    "id": "herdr",
    "key": "tabHerdrEnabled",
    "missingRequiredPermissions": [],
    "optionalCapabilities": [],
    "optionalPermissions": [],
    "requiredCapabilities": [
      "herdrSessions"
    ],
    "requiredPermissions": [],
    "requiredTools": [],
    "summary": "Live Herdr sessions on this Mac and your SSH machines.",
    "title": "Herdr"
  }
]
```

`group` is the readable group name, capitalised: `Agent`, `System`, `Media` or
`Utilities`. `key` is the preference `ed config` uses for the same feature.
`missingRequiredPermissions` is `requiredPermissions` filtered down to the ones
Edith's mirrored grant state does not say yes to, so it is the field to gate on
rather than parsing prose. `requiredCapabilities` and `optionalCapabilities`
come straight from the cross-platform registry. They describe implementation
requirements, not grants, and are never filtered for the current Mac.

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
