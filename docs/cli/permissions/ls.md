# `ed permissions ls`

Print the permission table as Edith last observed it. Reads the states out of
the shared defaults suite, and asks the app for nothing beyond whether its
process is up, which only `--json` needs, so it works whether or not Edith is
running.

```
ed permissions ls [--attention] [--json]
```

Aliases: `ed permissions list`. Default subcommand: `ed permissions` alone runs
it.

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--attention` | flag | off | Keep only permissions that block an enabled extension: not granted, and required (not merely optional) by at least one extension that is currently on |
| `--json` | flag | off | Emit JSON on stdout |

## `--json` shape

An object with `appRunning` and `permissions`, and one object per permission in
the fixed order of the table above. Trimmed here to three of the nine rows:

```json
{
  "appRunning": true,
  "permissions": [
    {
      "blocksEnabledExtension": true,
      "granted": false,
      "grantsOnFirstUse": false,
      "id": "calendar",
      "name": "Calendar",
      "optionalFor": [],
      "reason": "Required to read and show your schedule in Calendar.",
      "requiredBy": [
        "calendar"
      ],
      "usedByEnabledExtension": true
    },
    {
      "blocksEnabledExtension": false,
      "granted": true,
      "grantsOnFirstUse": false,
      "id": "screenRecording",
      "name": "Screen Recording",
      "optionalFor": [],
      "reason": "Required to detect shared content or sample colors from the screen.",
      "requiredBy": [
        "focusDim",
        "presenter",
        "colorPicker"
      ],
      "usedByEnabledExtension": true
    },
    {
      "blocksEnabledExtension": false,
      "granted": false,
      "grantsOnFirstUse": true,
      "id": "bluetooth",
      "name": "Bluetooth",
      "optionalFor": [
        "notchShelf"
      ],
      "reason": "Asked when Notch Shelf first checks for device connections.",
      "requiredBy": [],
      "usedByEnabledExtension": true
    }
  ]
}
```

`appRunning` reports whether the menu bar helper is up, which is how you tell a
live mirror from one that has not been touched since the app was last closed.
`requiredBy` and `optionalFor` list every extension that declares the
permission, enabled or not; `usedByEnabledExtension` and
`blocksEnabledExtension` are the two questions that account for which extensions
are actually on. `grantsOnFirstUse` is true exactly for `bluetooth` and
`automation`. `--attention` filters the `permissions` array the same way it
filters the human table, so the two flags combine.

## Examples

```
ed permissions ls
ed permissions ls --attention
ed permissions ls --json | jq -r '.permissions[] | select(.granted | not) | .id'
ed permissions ls --json | jq .appRunning
```

## Behaviour

The `STATE` column is `granted` when the mirror says so, `on first use` when the
permission cannot be requested, and `no` otherwise. The unnamed third column
holds `blocking` on any row that stops an enabled extension working. `USED BY`
lists only the extensions that are currently enabled, comma separated, so a
permission whose users are all switched off shows an empty column while `--json`
still names them under `requiredBy` and `optionalFor`.

```
$ ed permissions ls
PERMISSION       STATE                   USED BY
calendar         no            blocking  calendar
notifications    granted                 usage,machines
accessibility    granted                 system,clipboard
inputMonitoring  granted                 system
fullDisk         no
screenRecording  granted                 focusDim,presenter,colorPicker
camera           granted                 notchShelf
bluetooth        on first use            notchShelf
automation       on first use            notchShelf

$ ed permissions ls --attention
PERMISSION  STATE            USED BY
calendar    no     blocking  calendar
```

Nothing is mutated and nothing is asked of the app, so this exits 0 on every
machine, including one where Edith has never run and every mirror key is absent
and therefore false.

## Where to go next

- [`ed permissions`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
