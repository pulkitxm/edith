# `ed machines files reveal`

Downloads a remote file into Edith's preview cache and reveals it in Finder.

```
ed machines files reveal <machine> <path> [--json]
```

The Files pane and `launch` share the same materialized copy. `--json` performs
the reveal and reports `action`, `local`, `machine` and `remote`.

```
ed machines files reveal tuf /srv/reports/latest.pdf
```

A download failure exits 1. If Finder is unavailable, the command exits 4.

## Where to go next

- [`ed machines files launch`](./launch.md), open the file in its default app
- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
