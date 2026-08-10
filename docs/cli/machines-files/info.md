# `ed machines files info`

Measures how big something is, following a directory all the way down.

```
ed machines files info <machine> <path> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Which machine. |
| `path` | remote path | required | What to measure. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "machine": "Asus TUF 7",
  "path": "/var/log",
  "sizeBytes": 419430400
}
```

```
ed machines files info tuf /var/log
ed machines files info tuf /home/pulkit/uploads --json
ed machines tuf files info /srv
```

What runs is `du -sk <path>`, capped at 120 seconds, and the kilobytes are
multiplied by 1024. This is disk usage rather than the sum of file sizes, so it
counts whole blocks and answers for directories, which is the reason to use it
instead of reading `sizeBytes` out of `ed machines files ls`.

The human line is formatted by macOS rather than by Edith's own byte formatter,
so it reads the way Finder's Get Info reads:

```
$ ed machines files info tuf /var/log
419.4 MB  /var/log
```

`du`'s errors are discarded, so a path that does not exist is reported as
nothing at all rather than as a failure: the size is 0, the line reads
`Zero KB  /nope`, and the exit code is 0. Confirm the path with
`ed machines files ls` when a zero would be surprising.

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
