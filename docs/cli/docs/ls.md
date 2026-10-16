# `ed docs ls`

Lists the bundled reference pages in the order the Docs page shows them.

```
ed docs ls [--group <group>] [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--group <group>` | a folder under `docs/cli`, such as `herdr` or `machines-docker` | every group | Only the pages in that group |
| `--json` | flag | off | Emit JSON on stdout |

The human form is a two column table, `PATH` and `TITLE`. A group that does not
exist exits 3.

## `--json` shape

```json
{
  "pages": [
    {
      "command": "ed herdr ls",
      "group": "herdr",
      "path": "herdr/ls.md",
      "title": "ed herdr ls"
    }
  ]
}
```

`command` is `null` for pages that are not about one command, such as
[conventions and contracts](../conventions.md).

- [`ed docs`](./README.md)
- [All command groups](../README.md)
