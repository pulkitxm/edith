# `ed machines files preview`

Prints the first 400 KiB of a remote text file.

```
ed machines files preview <machine> <path> [--json]
```

The plain form writes the text to stdout. If the file is larger, a truncation
notice goes to stderr. `--json` returns `machine`, `path`, `text` and
`truncated`, so redirected output remains one valid document.

```
ed machines files preview tuf /etc/os-release
ed machines files preview tuf '/srv/app/config file' --json
```

The command uses the same byte limit and shell quoting as the Files preview
pane. A missing or unreadable path exits 1, and an unreachable machine exits 4.

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
