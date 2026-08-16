# `ed machines files mv`

Moves one or more paths into a directory on the machine. This is the window's
cut and paste.

```
ed machines files mv <machine> <path>... <directory> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Which machine. |
| `path...` | one or more remote paths, then the destination directory last | at least two values required | What to move, and where to. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "done": true,
  "into": "/home/pulkit/archive",
  "machine": "Asus TUF 7",
  "moved": [
    "/home/pulkit/old.log"
  ]
}
```

```
ed machines files mv tuf /home/pulkit/old.log /home/pulkit/archive
ed machines files mv tuf /srv/a.conf /srv/b.conf /srv/old
ed machines files mv tuf /tmp/build /srv/releases --json
```

Identical in shape to `cp` and identical in its refusals: fewer than two values
exits 1, a non-zero exit on the machine exits 1 with the machine's message, and
the cap is 300 seconds. What runs is plain `mv`, which means a file of the same
name in the destination is overwritten without a word. Check first with
`ed machines files ls` when that matters.

A move made here is not on any window's undo stack. Reverse it with another
`mv`, not with `ed machines files undo`.

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
