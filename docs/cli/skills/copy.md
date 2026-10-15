# `ed skills copy`

Prints a skill's complete Markdown, including its metadata, or copies that
text to the clipboard.

[`ed skills`](./README.md)

Usage:

```
ed skills copy <id> [--clipboard] [--json]
```

Arguments:

| Name | What it is |
| --- | --- |
| `<id>` | A skill id from `ed skills ls`. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--clipboard` | flag | off | Replaces the general pasteboard with the complete Markdown. |
| `--json` | flag | off | Emits the document as JSON. `copied` is true when the pasteboard was set. |

Without `--clipboard` the raw Markdown goes to stdout, which is what the Copy
button places on the pasteboard. `--clipboard` does that write itself and
prints `copied <id>`.

Examples:

```
ed skills copy edith-remote-work
ed skills copy edith-remote-work --clipboard
ed skills copy edith-video-edit --clipboard --json
```

See also:

- [`ed skills preview`](./preview.md)
- [`ed skills`](./README.md)
- [`ed`](../README.md)
