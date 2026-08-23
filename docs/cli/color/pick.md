# `ed color pick`

Requests the same system colour sampler as Edith's menu bar eyedropper, shelf
tile and global shortcut.

Usage:

```
ed color pick [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments. The plain response is one line:

```
color picker requested
```

The JSON response has two stable fields:

```json
{
  "operation": "color.pick",
  "requested": true
}
```

`requested` means the fire-and-forget request was sent to the running menu bar
app. The command exits after requesting the loupe. It does not wait for a colour, and
canceling the loupe does not change the already completed command. A successful
sample is copied in `colorPickerCopyFormat`, added to the front of the shared
history and visible through `ed color ls`.

The command does not read stdin or require a terminal, so a script can request
it with redirected streams. The interaction still happens on the logged-in
desktop. A headless session cannot usefully finish the pick.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | The sampler request was sent. |
| 2 | The command line was invalid. |
| 4 | The Color Picker extension is off, or Edith's menu bar app is not running. |

When the extension is off, enable it first:

```
ed extensions enable colorPicker
ed color pick
```

When Edith is closed, start it and retry. The command never starts Edith by
itself, never changes the extension setting and never writes a synthetic
swatch. Screen Recording access is still enforced by macOS when the system
sampler opens.

## Where to go next

- [`ed color ls`](./ls.md), to read a completed sample
- [`ed color`](./README.md), the rest of this group
- [`ed permissions`](../permissions/README.md), for Screen Recording access
