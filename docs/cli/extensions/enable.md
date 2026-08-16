# `ed extensions enable`

Turns one extension on.

```
ed extensions enable <id> [--json]
```

| Argument | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `id` | one of the fourteen ids, or a defaults key | required | The extension to turn on |

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit the extension's record on stdout instead of the one-line confirmation |

The write is unconditional: the key is set to `true`, the store is synchronised,
and `settingsChanged` is posted, whether or not the extension was already on.
Then, in the human form, any required permission Edith has not recorded as
granted is named on stderr, one line each, with the command that asks for it:

```
$ ed extensions enable focusDim
focusDim enabled
note: Focus Dim needs Screen Recording; run `ed permissions request screenRecording`
```

The first line is stdout, the `note:` line is stderr, and the exit code is 0
either way. This is the one place `ed` deliberately differs from the switch on
each row of the Extensions page: the pane refuses the toggle when a required
permission is missing and opens the permission sheet instead, leaving the switch
off, while `ed` turns the extension on and tells you what it still needs. The
extension is on and inert until the grant lands.

`--json` prints the same record `info` prints, already reflecting the new state,
and prints no note at all: the missing permissions are in
`missingRequiredPermissions`.

```json
{
  "enabled": true,
  "featured": false,
  "group": "Utilities",
  "id": "focusDim",
  "key": "focusDimEnabled",
  "missingRequiredPermissions": [
    "screenRecording"
  ],
  "optionalCapabilities": [],
  "optionalPermissions": [],
  "requiredCapabilities": [
    "windowDimming"
  ],
  "requiredPermissions": [
    "screenRecording"
  ],
  "requiredTools": [],
  "summary": "Dims everything behind your active app.",
  "title": "Focus Dim"
}
```

```
ed extensions enable clipboard
ed extensions enable machines
ed extensions enable notchShelfEnabled
ed extensions enable focusDim --json
```

An unknown id is refused before anything is written, and exits 3 with every
known id as the hint:

```
$ ed extensions enable clipbored
error: no extension named clipbored
hint: known ids: usage, system, machines, companion, systemStats, micMute, lidAwake, music, calendar, notchShelf, clipboard, focusDim, presenter, colorPicker
```

Enabling never asks for a permission and never installs a tool. `music` wants
`yt-dlp` and `usage` wants `claude` and `codex`, and `ed` reports them in
`requiredTools` rather than fetching them; `ed tools ls` and
`ed tools install <id>` are the verbs for that.

## Where to go next

- [`ed extensions`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
