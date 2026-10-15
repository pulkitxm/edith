# `ed app actions`

Lists the seven one-shot actions with the process each one needs and whether
that process is running.

```
ed app actions [--json]
```

`ls` is an alias, and `actions` is the group's default subcommand, so
`ed app actions`, `ed app ls` and a bare `ed app` all print the same table.

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |

`--json` shape, a top-level array with one object per action:

```json
[
  {
    "action": "clean-keys",
    "available": true,
    "needs": "menuBar",
    "summary": "Lock the keyboard so it can be wiped."
  },
  {
    "action": "test-notification",
    "available": true,
    "needs": "menuBar",
    "summary": "Send a test notification."
  },
  {
    "action": "open",
    "available": true,
    "needs": "menuBar",
    "summary": "Open the Edith panel."
  },
  {
    "action": "quit",
    "available": false,
    "needs": "mainApp",
    "summary": "Quit the Edith main window."
  },
  {
    "action": "check-updates",
    "available": false,
    "needs": "mainApp",
    "summary": "Ask Sparkle to check for an update now."
  },
  {
    "action": "reveal",
    "available": false,
    "needs": "mainApp",
    "summary": "Show a section of the main window."
  },
  {
    "action": "snapshot",
    "available": false,
    "needs": "mainApp",
    "summary": "Capture the open windows as PNG files."
  }
]
```

`needs` is `menuBar` or `mainApp`, never anything else. `available` is the live
answer for that one process, so the four `mainApp` rows can be false while the
three `menuBar` rows are true.

Examples:

```
ed app actions
ed app ls --json
ed app
```

This command reads the process table and nothing else: it changes nothing, needs
neither process, and reports a closed app as `available: false` rather than
failing, so it always exits 0. It is the cheap way to find out whether the next
verb will work.

```
$ ed app actions
ACTION             NEEDS     STATE  WHAT
clean-keys         menu bar  ready  Lock the keyboard so it can be wiped.
test-notification  menu bar  ready  Send a test notification.
open               menu bar  ready  Open the Edith panel.
quit               main app  ready  Quit the Edith main window.
check-updates      main app  ready  Ask Sparkle to check for an update now.
reveal             main app  ready  Show a section of the main window.
snapshot           main app  ready  Capture the open windows as PNG files.
```

The human table writes `needs` as `menu bar` or `main app`, and `STATE` as
`ready` or `app not running`.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
