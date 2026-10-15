# `ed bifrost open`

Asks the running menu bar app to open the Bifrost bar, the same panel the global
shortcut opens, optionally with text already in the field.

Usage:

```
ed bifrost open [<query>] [--json]
```

Arguments and options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<query>` | text | empty | Fills the search field before the bar appears. |
| `--json` | flag | off | Emits one JSON document on stdout. |

The plain response is one line:

```
launcher requested
```

The JSON response has three stable fields:

```json
{
  "operation": "bifrost.open",
  "requested": true,
  "query": "safari"
}
```

`requested` means the fire-and-forget request was sent to the running menu bar
app. The command exits there. It does not wait for you to choose anything, and
dismissing the bar does not change the already completed command.

Without a query the request toggles, so a second `ed bifrost open` while the bar
is up closes it again. With a query it always shows the bar and replaces
whatever was in the field, which is what makes
`ed bifrost open "12 km in miles"` a reasonable thing to bind to a key.

The field is an ordinary text field: ⌘A selects all, ⌘C, ⌘V and ⌘X work, and
⌘Z and ⇧⌘Z undo and redo. The bar routes those itself, because a menu bar app
has no Edit menu to carry them.

Return runs the selected row: an application opens, an answer goes to the
pasteboard. `⌥`-return copies whatever is selected instead, so an application
row hands you its path rather than launching it, and either way the bar
dismisses.

The shortcut is `⌥space` unless you have rebound it in Settings > Shortcuts,
which writes `bifrostHotKeyCode`, `bifrostHotKeyMods` and `bifrostHotKeyLabel`.
The bar opens where `bifrostPopupAt` says: `center` by default, or `cursor`,
`statusItem`, `window` or `lastPosition`.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | The request was sent. |
| 2 | The command line was invalid. |
| 4 | The Bifrost extension is off, or Edith's menu bar app is not running. |

The extension is checked first, before the app, so an off extension is reported
as an off extension even when Edith is closed:

```
ed extensions enable bifrost
ed bifrost open
```

The command never starts Edith by itself, never changes the extension setting
and never touches the frequency ledger: nothing is recorded until you actually
pick something in the bar.

## Where to go next

- [`ed bifrost ls`](./ls.md), to see what the bar can find
- [`ed bifrost`](./README.md), the rest of this group
- [`ed extensions`](../extensions/README.md), to turn Bifrost on
- [All `ed` commands](../README.md)
