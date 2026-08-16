# `ed machines files cp`

Copies one or more paths into a directory on the machine. This is the window's
copy and paste.

```
ed machines files cp <machine> <path>... <directory> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Which machine. |
| `path...` | one or more remote paths, then the destination directory last | at least two values required | What to copy, and where to. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "copied": [
    "/Users/pulkit/notes.md",
    "/Users/pulkit/deploy.sh"
  ],
  "done": true,
  "into": "/Users/pulkit/backup",
  "machine": "Studio Mac"
}
```

```
ed machines files cp studio /Users/pulkit/notes.md /Users/pulkit/backup
ed machines files cp studio /srv/a.conf /srv/b.conf /srv/keep
ed machines files cp studio /var/log/system.log /tmp --json
```

The last value is always the destination, like the shell tool this mirrors, and
the rest are sources. Fewer than two values exits 1 with `give at least one
source and a destination directory`.

What runs is `cp -a`, so a directory is copied whole and modes, ownership where
the account is allowed to set it, and timestamps are preserved. The destination
is not checked for being a directory: with exactly one source and a destination
that does not exist, this copies the source to that name, which is `cp`
behaviour rather than a special case.

The command is capped at 300 seconds. Without `--json` the output is a single
line saying what was done, `copied 2 into /Users/pulkit/backup`. A non-zero exit
on the machine exits 1 with that same description and whatever the machine
printed:

```
$ ed machines files cp studio /srv/a.conf /srv/locked
error: copied 1 into /srv/locked failed on Studio Mac: cp: cannot create regular file '/srv/locked/a.conf': Permission denied
```

`done` is `true` in every JSON document this prints, because a failure never
gets that far; it is the field to assert on rather than to branch on.

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
