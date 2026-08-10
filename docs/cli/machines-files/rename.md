# `ed machines files rename`

Renames one path, leaving it in the directory it is already in.

```
ed machines files rename <machine> <path> <name> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Which machine. |
| `path` | remote path | required | What to rename. |
| `name` | a bare name, no slashes | required | What to call it. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "done": true,
  "machine": "Asus TUF 7",
  "path": "/home/pulkit/notes.md",
  "to": "/home/pulkit/journal.md"
}
```

```
ed machines files rename tuf /home/pulkit/notes.md journal.md
ed machines files rename tuf /srv/app.conf app.conf.bak
ed machines files rename tuf /tmp/report.txt summary.txt --json
```

The new name is joined to the original path's directory, so the file stays
where it is. A name containing a slash is refused before anything is sent, and
exits 1 rather than 2:

```
$ ed machines files rename tuf /home/pulkit/notes.md sub/journal.md
error: a new name cannot contain a slash
hint: use `ed machines files mv` to move it somewhere else
```

The rename is guarded on the machine: it tests for the target first and gives up
with status 17 if something is already there, so an existing name is refused
rather than overwritten. That guard prints nothing, which is why the refusal
arrives without detail:

```
$ ed machines files rename tuf /home/pulkit/notes.md deploy.sh
error: renamed to /home/pulkit/deploy.sh failed on Asus TUF 7
```

The `to` field carries the full new path, not the bare name you typed, and so
does the human line, which reads `renamed to /home/pulkit/journal.md`.

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
