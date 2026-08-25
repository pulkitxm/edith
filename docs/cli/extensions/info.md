# `ed extensions info`

Describes one extension without changing anything.

```
ed extensions info <id> [--json]
```

| Argument | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `id` | one of the seventeen ids, or a defaults key | required | The extension to describe |

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the indented block |

The human form is the title, the lifecycle value, then labelled rows and the
shared workflow, setup, verification, recovery and documentation guidance. The
`needs` row appears only when the extension has required permissions and the
`asks for` row only when it has optional ones. `state` is the computed lifecycle
phase, not just the stored on or off switch:

```
$ ed extensions info clipboard
Clipboard
  Keep recent clipboard entries searchable and paste them without context switching.
  id       clipboard
  key      clipboardEnabled
  group    Utilities
  state    Ready
  runtime  Installed
  asks for Accessibility
```

```
$ ed extensions info calendar
Calendar
  See upcoming events beside your work and jump into the next meeting.
  id       calendar
  key      tabCalendarEnabled
  group    Media
  state    Disabled
  runtime  Uninstalled
  needs    Calendar
```

`needs` and `asks for` print the readable permission names (`Input Monitoring`,
`Screen Recording`), while `--json` prints the ids `ed permissions request`
accepts (`inputMonitoring`, `screenRecording`).

The JSON object retains the registry fields documented by `ls` and adds:

| Field | Shape | Meaning |
| --- | --- | --- |
| `lifecycle` | object | Value, workflows, prerequisites, CLI examples, docs, recovery and verification metadata |
| `state` | object | Readiness phase, runtime phase, summary and structured issues |
| `checks` | array | Every readiness check with status, runtime phase contribution, detail and optional recovery command |
| `verified` | boolean | True only when every required check passes |

```
ed extensions info notchShelf
ed extensions info music --json
ed extensions info tabMachinesEnabled
```

`info` is a pure read: no key is written and no notification is posted. It runs
the same readiness probe as `status`, `verify`, `doctor`, and the Extensions
settings sheet. Use `--json` for the complete machine-readable contract.

## Where to go next

- [`ed extensions`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
