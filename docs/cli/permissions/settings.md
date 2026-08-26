# `ed permissions settings`

Open the System Settings destination for one permission without raising a prompt
or relaunching Edith.

```
ed permissions settings <permission> [--json]
```

The permission id is completed from the same ten-value catalogue used by
`request`. Application Audio and Bluetooth are granted when their features first
run, but their privacy panes can still be opened here. Automation has no direct
destination and exits 4 with its first-use explanation.

## `--json` shape

```json
{
  "opened": true,
  "permission": "screenRecording",
  "url": "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
}
```

The command exits 0 only after macOS accepts the Settings URL. It does not need
the Edith menu bar helper because opening a settings pane belongs to the local
Mac where `ed` is running.

## Examples

```
ed permissions settings calendar
ed permissions settings screenRecording --json
ed permissions settings applicationAudio
```

## Where to go next

- [`ed permissions`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
