# `ed quick-actions`

Quick Actions exposes the same one-click macOS controls shown in Edith's menu
bar panel and extension settings.

```text
ed quick-actions status [--json]
ed quick-actions appearance [--json]
ed quick-actions keyboard-light [--json]
ed quick-actions empty-trash [--yes] [--json]
ed quick-actions eject-disks [--json]
ed quick-actions hidden-files [--json]
ed quick-actions desktop-icons [--json]
ed quick-actions lock-screen [--json]
```

A bare `ed quick-actions` runs `status`. Its JSON document includes extension
enablement, visibility, availability, display state, and a complete snapshot.
Action JSON includes `action`, `operation`, `applied`, `changed`,
`affectedCount`, `message`, and the resulting `snapshot`.

Enable the extension before changing state:

```bash
ed extensions enable quickActions
ed quick-actions status --json
```

`appearance`, `keyboard-light`, `hidden-files`, and `desktop-icons` toggle their
current state. The keyboard command exits as unavailable when the Mac has no
controllable built-in keyboard backlight. Finder preference changes restart
Finder so the result appears immediately.

`eject-disks` only targets local, non-root volumes identified by macOS as
external, removable, or ejectable. Internal fixed disks, network mounts, and
the startup volume are never selected.

`empty-trash` is permanent. Without `--yes`, it prints a plan and changes
nothing. The settings and panel buttons require the same explicit confirmation.
`lock-screen` locks the current session immediately.

- [`ed extensions`](../extensions/README.md)
- [`ed config`](../config/README.md)
- [All command groups](../README.md)
