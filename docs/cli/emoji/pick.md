# `ed emoji pick`

Asks the running menu bar app to open Edith's emoji picker, the same panel the
global shortcut opens.

Usage:

```
ed emoji pick [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments. The plain response is one line:

```
emoji picker requested
```

The JSON response has two stable fields:

```json
{
  "operation": "emoji.pick",
  "requested": true
}
```

`requested` means the fire-and-forget request was sent to the running menu bar
app. The command exits there. It does not wait for you to choose anything, and
dismissing the panel does not change the already completed command. Picking an
emoji in the panel types it into the app that was frontmost and records the use,
exactly as [`ed emoji insert`](./insert.md) does.

The shortcut is `⌃⇧E` unless you have rebound it in Settings > Shortcuts, which
writes `emojiHotKeyCode`, `emojiHotKeyMods` and `emojiHotKeyLabel`. The panel
opens where `emojiPopupAt` says: `cursor` by default, or `statusItem`, `window`,
`center` or `lastPosition`.

The request toggles rather than shows, so a second `ed emoji pick` while the
panel is open closes it again. That is worth knowing before putting the command
behind a repeating trigger.

The command does not read stdin or require a terminal, so a script can request it
with redirected streams. The panel is a floating non-activating panel that takes
key focus for its own search field and hands focus back when it dismisses, so
the interaction still needs a person at the logged-in desktop.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | The picker request was sent. |
| 2 | The command line was invalid. |
| 4 | The Emoji Picker extension is off, or Edith's menu bar app is not running. |

The extension is checked first, before the app, so an off extension is reported
as an off extension even when Edith is closed:

```
ed extensions enable emoji
ed emoji pick
```

When Edith is closed, start it and retry. The command never starts Edith by
itself, never changes the extension setting and never touches the frequency
ledger: nothing is recorded until an emoji is actually chosen.

## Where to go next

- [`ed emoji insert`](./insert.md), to type one without the panel
- [`ed emoji`](./README.md), the rest of this group
- [`ed extensions`](../extensions/README.md), to turn the picker on
- [All `ed` commands](../README.md)
