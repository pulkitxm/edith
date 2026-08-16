# `ed lid-awake`

`ed lid-awake` controls every part of the Lid Awake extension from the shell.
Running it without a subcommand is the same as `ed lid-awake status`.

| Command | What it does |
| --- | --- |
| [`ed lid-awake status`](./status.md) | Show active state, session, remaining time, battery policy and helper state |
| [`ed lid-awake on`](./on.md) | Turn Lid Awake on indefinitely |
| `ed lid-awake on --for 15m` | Turn it on for 15 minutes |
| `ed lid-awake on --for 30m` | Turn it on for 30 minutes |
| `ed lid-awake on --for 1h` | Turn it on for one hour |
| `ed lid-awake on --for 2h` | Turn it on for two hours |
| `ed lid-awake on --until-lid-reopens` | Stop after the lid closes and opens again |
| [`ed lid-awake off`](./off.md) | Restore normal lid-close sleep |
| [`ed lid-awake battery 20`](./battery.md) | Pause below 20 percent battery |
| `ed lid-awake battery off` | Disable battery auto-pause |
| [`ed lid-awake restore-on-quit true`](./restore-on-quit.md) | Restore normal sleep when the menu bar app quits |

`on`, `off` and live `status` use the running menu bar app. They wait for the
same engine used by the shelf and extension popup, so a successful command means
the system setting was actually applied. `on` enables the extension if needed.
The first activation opens System Settings when macOS still needs approval for
Edith's background helper. Turn on the Edith item that affects all users once,
then run the command again. Later changes use that helper without asking for the
administrator password again. Edith does not fall back to a password dialog.

`status` also works while Edith is closed. In that case it reports the last
stored state with `appRunning` set to `false` and `helperStatus` set to
`unavailable`.

## Commands

- [`ed lid-awake status`](./status.md)
- [`ed lid-awake on`](./on.md)
- [`ed lid-awake off`](./off.md)
- [`ed lid-awake battery`](./battery.md)
- [`ed lid-awake restore-on-quit`](./restore-on-quit.md)

## JSON

Every command accepts `--json`. `status`, `on` and `off` return the same full
state object:

```json
{
  "active": true,
  "appRunning": true,
  "applying": false,
  "batterySuspended": false,
  "batteryThreshold": 20,
  "extensionEnabled": true,
  "helperStatus": "enabled",
  "lastError": null,
  "remainingSeconds": 1799.5,
  "requestedActive": true,
  "restoreOnQuit": true,
  "session": "thirtyMinutes"
}
```

`remainingSeconds` and `lastError` are always present in JSON and are `null`
when there is no deadline or failure. `helperStatus` is `enabled`,
`awaitingApproval`, `notRegistered`, `notFound` or, when the app is closed,
`unavailable`. `battery` returns only `batteryThreshold`, and
`restore-on-quit` returns only `restoreOnQuit`.

Persistent values are also available through `ed config`:

```bash
ed config get lidAwakeActive
ed config set lidAwakeEnabled true
ed config set lidAwakeSession oneHour
ed config set lidAwakeBatteryThreshold 20
ed config set lidAwakeRestoreOnQuit true
```

`lidAwakeActive` is read only because changing a preference cannot change the
system power state. Use `ed lid-awake on` and `ed lid-awake off` for that.
The other four keys are persistent settings, but changing them does not perform
a runtime action. In particular, bare `ed lid-awake on` explicitly selects an
indefinite session. It does not reuse `lidAwakeSession`; pass `--for` or
`--until-lid-reopens` when starting from the CLI.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The request completed |
| 1 | The helper or `pmset` rejected the change, or a value was invalid |
| 2 | The command syntax was invalid |
| 4 | A runtime action needed the menu bar app, or the app did not answer |

[Back to the CLI index](../README.md)
