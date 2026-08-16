# `ed permissions request`

Ask the running app to raise the macOS prompt for one permission, wait for it,
then report the mirror. This is the button on a row of the Permissions pane.

```
ed permissions request <permission> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<permission>` | one of `calendar`, `notifications`, `accessibility`, `inputMonitoring`, `fullDisk`, `screenRecording`, `camera`, `bluetooth`, `automation` | required | The permission to ask for. Matched case-insensitively, so `INPUTMONITORING` resolves the same as `inputMonitoring` |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout |

## `--json` shape

```json
{
  "granted": false,
  "permission": "calendar"
}
```

`permission` is the id you asked for, normalised to the catalogue's spelling.
`granted` is the mirror re-read after the wait, not a promise that the prompt
was answered.

## Examples

```
ed permissions request calendar
ed permissions request screenRecording --json
ed permissions request notifications && ed app relaunch
```

## Behaviour

The three checks run in this order, and the first one that fails is the one you
see:

1. the id is looked up, and an unknown one exits 3 listing all nine,
2. `bluetooth` and `automation` are refused, because they have no prompt to
   raise, and exit 4,
3. the menu bar app must be running, and exit 4 says so when it is not.

Because the refusal is checked before the app is, asking for `bluetooth` with
Edith closed still tells you the useful thing:

```
$ ed permissions request bluetooth
error: Bluetooth is granted on first use and cannot be requested
hint: macOS will ask for Bluetooth access when connection alerts first run.

$ ed permissions request wifi
error: no permission named wifi
hint: known: calendar, notifications, accessibility, inputMonitoring, fullDisk, screenRecording, camera, bluetooth, automation
```

Past those checks the command posts the permission's grant notification, sleeps
1500 ms, posts a refresh, sleeps another 1000 ms, and reads the mirror. So it
takes at least two and a half seconds, and it is a fixed wait rather than a
reply it can wait on. The app's side of that notification opens the matching
System Settings pane on your screen, which is a visible side effect of a command
you may have run over SSH.

A grant that has not landed inside those two and a half seconds is the normal
outcome for anything you have to toggle in System Settings by hand. The command
reports it and still exits 0, so gate on the `granted` field rather than on the
exit code:

```
$ ed permissions request calendar
calendar not granted yet
note: finish the prompt in System Settings, then run `ed permissions refresh`
```

Accessibility, Input Monitoring and Screen Recording only take effect for a
process that starts after the grant, so follow a successful request with
`ed app relaunch`.

## Where to go next

- [`ed permissions`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
