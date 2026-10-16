# `ed machines files launch`

Downloads a remote file into Edith's preview cache and opens it in its default
Mac app.

```
ed machines files launch <machine> <path> [--json]
```

The cache key includes the machine, remote path, size and modification stamp
when available. The Files pane uses the same cache and materialization path.
`--json` opens the file and then reports `action`, `local`, `machine` and
`remote`.

```
ed machines files launch tuf /srv/reports/latest.pdf
```

A download failure exits 1. If macOS cannot open the local file, the command
exits 4.

## Where to go next

- [`ed machines files reveal`](./reveal.md), show the downloaded file in Finder
- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
