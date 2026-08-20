# `ed app reveal`

Shows a section of the main window, and optionally a tab inside it.

```
ed app reveal [<section>] [--tab <tab>] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<section>` | `home`, `dashboard`, `herdr`, `music`, `calendar`, `system`, `machines`, `companion`, `extensions`, `settings`, `about` | none | The sidebar section to show. Without it the window comes up where it already was, and the answer names that section. |
| `--tab` | section-specific | none | A tab inside the section. `companion` has `chat`, `capture`, `desk`, `library`, `mind`, `setup`, `settings`; `settings` has `general`, `permissions`, `shortcuts`, `terminal`, `icloud`, `updates`. |
| `--json` | flag | off | Emit JSON on stdout. |

`--json` shape:

```json
{
  "action": "reveal",
  "section": "companion",
  "tab": "chat"
}
```

Examples:

```
ed app reveal
ed app reveal companion
ed app reveal companion --tab settings
ed app reveal settings --tab permissions
ed app reveal machines --json
```

The app answers when the section is on screen, so a `0` exit means the window
is open and showing what you asked for, not merely that a request was sent.
A section that does not exist, a tab that does not belong to the section, or
`--tab` on a section that has none all exit 3 with the valid names in the
error, and `--tab` without a section is a usage error, exit 2. The main window
process must be running; without it the command exits 4.
Section and tab values are exact, lowercase raw values. An explicitly empty
`--tab ''` is treated as no tab and reveals only the section. A bare reveal
returns the stored section but does not return that section's current tab, so
its JSON has `"tab": null`.

Pairs with [`ed app snapshot`](./snapshot.md) for reading the screen you just
revealed.

## Where to go next

- [`ed app snapshot`](./snapshot.md), capture what you revealed
- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
