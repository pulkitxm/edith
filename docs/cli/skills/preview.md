# `ed skills preview`

Prints a skill's Markdown body, the same text the preview sheet renders.

[`ed skills`](./README.md)

Usage:

```
ed skills preview <id> [--json]
```

Arguments:

| Name | What it is |
| --- | --- |
| `<id>` | A skill id from `ed skills ls`, such as `edith-remote-work`. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits the document, including the full Markdown, as JSON. |

This reads GitHub and may fall back to the cached copy. It does not install
the skill. `cached` is true when the printed text came from that cache.

`--json` shape:

```json
{
  "body": "# Remote work",
  "cached": false,
  "id": "edith-remote-work",
  "markdown": "---\nname: edith-remote-work\n---\n# Remote work\n",
  "name": "Edith Remote Work"
}
```

Examples:

```
ed skills preview edith-remote-work
ed skills preview edith-remote-work --json
```

See also:

- [`ed skills copy`](./copy.md)
- [`ed skills`](./README.md)
- [`ed`](../README.md)
