# `ed music mkdir`

Makes a folder in the library. Aliased `newfolder`.

```
ed music mkdir <name> [--under <folder>] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `name` | text | required | What to call it. |
| `--under` | path relative to the library root | `""`, the root | Folder to make it inside. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "name": "Chill",
  "path": "Focus/Chill"
}
```

```
ed music mkdir Chill
ed music mkdir Deep --under Focus
ed music mkdir "Late Night" --json
```

The name is sanitised before use: it is trimmed, and `/` and `:` each become
`-`, so a name cannot escape the folder it was asked for. A name that is blank
after trimming exits 1 with `a name cannot be blank`, and a folder that already
exists exits 1 with `<path> is already there` rather than being reused. A
`--under` that does not exist exits 3. On success `ed` posts
`musicFolderChanged`, so an open Edith picks the new folder up without a
rescan.

## Where to go next

- [`ed music`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
