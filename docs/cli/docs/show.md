# `ed docs show`

Prints one reference page as Markdown. Name the page by its path, or by a
command it documents.

```
ed docs show <page-or-command> [--json]
```

```sh
ed docs show herdr/ls.md
ed docs show herdr ls
ed docs show ed machines docker prune --json
```

A path may drop `.md`, and a group name opens its README. A command may start
with `ed` or not. A command without a page of its own resolves to the section of
its group page that describes it, and `anchor` names that section.

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout |

## `--json` shape

```json
{
  "anchor": null,
  "anchors": [
    { "anchor": "ed-herdr-ls", "level": 1, "title": "ed herdr ls" },
    { "anchor": "options", "level": 2, "title": "Options" }
  ],
  "markdown": "# `ed herdr ls`\n...",
  "path": "herdr/ls.md",
  "title": "ed herdr ls"
}
```

`anchors` lists every heading with the slug the Docs page scrolls to. Nothing
that matches exits 3 with empty stdout.

- [`ed docs`](./README.md)
- [All command groups](../README.md)
