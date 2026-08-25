# `ed status`

Reports the same command-line tool and shell completion state shown in Edith's
Terminal settings.

```
ed status [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit one structured status document. |

The JSON document contains `tools`, `completions`, and `fallbackSource`.
`tools` reports the target directory, linked and missing names, whether the
directory is on `PATH`, whether this build bundles the tools, and whether the
installation is complete. Each completion reports its shell, state, path, and
optional hint.

```json
{
  "completions": [
    {
      "hint": null,
      "path": "/Users/me/.local/share/zsh/site-functions/_ed",
      "shell": "zsh",
      "state": "current"
    }
  ],
  "fallbackSource": "source $HOME/.local/share/zsh/site-functions/_ed",
  "tools": {
    "bundled": true,
    "complete": true,
    "directory": "/Users/me/.local/bin",
    "linked": ["ed", "edh", "edith"],
    "missing": [],
    "onPath": true
  }
}
```

This command only reads the file system and shared defaults. It works while
Edith is closed and exits 0 even when tools or completion scripts are missing.

## Where to go next

- [Getting started with `ed`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
