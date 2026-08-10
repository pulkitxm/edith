# `ed uninstall`

Removes the `ed`, `edh` and `edith` links, and leaves everything else in place.

```
ed uninstall [--json]
```

Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of a sentence |

`--json` shape:

```json
{
  "directory": "/Users/pulkit/.local/bin",
  "removed": [
    "ed",
    "edh",
    "edith"
  ]
}
```

Examples

```
ed uninstall
ed uninstall --json
```

The key is `removed`, not `linked`; `install` and `uninstall` do not share a
field name for the list of names they touched.

There is no `--directory` here. Uninstall always looks in the same preferred
directory `install` would have chosen, so links you placed elsewhere with
`ed install --directory ~/bin` are not removed and have to be deleted by hand.
Only symlinks are removed, and any symlink at one of those three names goes
whatever it points at. A regular file called `ed` is left alone.

Nothing about it can fail: an empty directory prints `nothing to remove in
<directory>` and exits 0.

## Where to go next

- [Getting started with `ed`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
