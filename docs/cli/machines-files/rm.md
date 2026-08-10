# `ed machines files rm`

Moves paths to the machine's trash, or with `--delete` removes them for good.

```
ed machines files rm <machine> <path>... [--delete] [--yes] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Which machine. |
| `path...` | one or more remote paths | at least one required | What to remove. |
| `--delete` | flag | off | Delete outright rather than moving to the trash. |
| `--yes` | flag | off | Actually do it. Required with `--delete`, and ignored without it. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "deleted": false,
  "done": true,
  "machine": "Asus TUF 7",
  "paths": [
    "/home/pulkit/old.log"
  ]
}
```

The dry run that `--delete` without `--yes` produces is a different, shorter
document, with neither `machine` nor `done`:

```json
{
  "deleted": false,
  "paths": [
    "/home/pulkit/old.log"
  ]
}
```

```
ed machines files rm tuf /home/pulkit/old.log
ed machines files rm tuf /tmp/a /tmp/b
ed machines files rm tuf /tmp/scratch --delete --yes
ed machines files rm tuf /tmp/scratch --delete --json
```

Trashing is the default and needs no confirmation, because it is reversible.
`--delete` is not, so it does nothing without `--yes`, reports what it would
have done, and still exits 0:

```
$ ed machines files rm tuf /tmp/scratch --delete
would delete 1 path(s) for good
nothing was deleted; pass --yes to go ahead
```

The trash is the freedesktop location in the login account's home,
`~/.local/share/Trash/files`, with a matching `.trashinfo` record in
`~/.local/share/Trash/info` holding the original path and the deletion time, so
the machine's own file manager can put the file back. Both directories are
created if they are missing. A name already sitting in the trash gets the
current epoch seconds appended rather than clobbering what is there. `--delete`
skips all of that and runs `rm -rf`.

Naming no path at all exits 1 with `name at least one path`, because the paths
argument accepts an empty list at the parser level. The cap is 300 seconds, and
a failure on the machine exits 1 with its message.

`deleted` in the JSON reports which of the two removals ran, not whether it
worked. `done` is what says it worked, and a dry run has no `done` at all.

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
