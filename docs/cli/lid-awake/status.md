# `ed lid-awake status`

Shows whether Lid Awake is active, which session is selected, how much time is
left, whether low battery paused it, and whether the privileged helper is ready.
It is the default subcommand, so bare `ed lid-awake` runs the same command.

```
ed lid-awake status [--json]
```

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit the full state object on stdout. |

The human form is a fixed set of labelled lines. `remaining` appears only for a
timed session and is rounded up to a whole second. `last error` appears only
when the engine or helper has an error:

```
$ ed lid-awake status
state: on
session: 30 minutes
remaining: 1799 seconds
battery auto-pause: 20%
restore on quit: on
helper: enabled
app running: yes
```

`state` is `changing`, `paused on low battery`, `on` or `off`, in that priority
order. `requestedActive` in JSON keeps the user's intent while low battery has
made `active` false. `applying` identifies a system change in flight, and
`extensionEnabled` identifies the extension switch separately from both.

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

With the menu bar app running, this waits up to three seconds for the live
engine. If it does not answer, the command exits 4. With the app closed, status
does not fail. It reads the stored extension, active, session, threshold and
restore values, returns `appRunning: false`, `helperStatus: "unavailable"`,
`applying: false`, `batterySuspended: false`, and no remaining time or last
error. That closed-app answer is persisted state, not a fresh `pmset` reading.

## Where to go next

- [`ed lid-awake`](./README.md), the rest of this group
- [`ed lid-awake on`](./on.md), start a session
- [All `ed` commands](../README.md)
