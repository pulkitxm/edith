# `ed lid-awake restore-on-quit`

Chooses whether the menu bar app restores normal lid-close sleep when its Lid
Awake engine shuts down.

```
ed lid-awake restore-on-quit <enabled> [--yes] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<enabled>` | boolean | required | Turn restoration on or off. |
| `--yes` | flag | off | Apply disabling restoration after previewing it. |
| `--json` | flag | off | Emit the preview or stored boolean as JSON. |

Boolean spellings are case-insensitive: `true`, `yes`, `on`, `1` and `enabled`
turn it on; `false`, `no`, `off`, `0` and `disabled` turn it off. Other text
exits 1 without changing the stored value.

```
ed lid-awake restore-on-quit true
ed lid-awake restore-on-quit off
ed lid-awake restore-on-quit false --yes --json
```

Turning restoration on applies immediately. Turning it off without `--yes`
previews the safety impact and does not write the preference. Its JSON preview
uses the same stable fields as `lid-awake on`, with `restoreOnQuit: false` and
`session: null`. Pass `--yes` to store the change.

Applied human output is `restore on quit = on` or `restore on quit = off`. JSON
contains only the stored boolean:

```json
{
  "restoreOnQuit": true
}
```

This is a preference write, so it works with Edith closed and posts
`settingsChanged` for a running app. It does not change the current system
state. Quitting only the main window with `ed app quit --yes` leaves the menu bar app
and the Lid Awake engine running, so it does not trigger this policy. Fully
terminating or uninstalling the menu bar feature does.

## Where to go next

- [`ed lid-awake`](./README.md), the rest of this group
- [`ed lid-awake status`](./status.md), see the current policy
- [`ed config get lidAwakeRestoreOnQuit`](../config/get.md), read the same preference
- [All `ed` commands](../README.md)
