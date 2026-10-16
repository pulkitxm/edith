# `ed machines files cp`

Copies one or more paths into a directory on the machine. This is the window's
copy and paste.

```
ed machines files cp <machine> <path>... <directory> [--dry-run] [--replace] [--yes] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Which machine. |
| `path...` | one or more remote paths, then the destination directory last | at least two values required | What to copy, and where to. |
| `--dry-run` | flag | off | Print the exact resolved destinations without copying. |
| `--replace` | flag | off | Target an existing matching name instead of making a numbered copy. |
| `--yes` | flag | off | Confirm replacements requested with `--replace`. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "operation": "machines.files.copy-within-machine",
  "machine": "Asus TUF 7",
  "destination": "/home/pulkit/backup",
  "dryRun": false,
  "executed": true,
  "requiresConfirmation": false,
  "items": [{
    "source": "/home/pulkit/notes.md",
    "destination": "/home/pulkit/backup/notes 2.md",
    "replacesExisting": false
  }],
  "skipped": []
}
```

```
ed machines files cp tuf /home/pulkit/notes.md /home/pulkit/backup
ed machines files cp tuf /srv/a.conf /srv/b.conf /srv/keep
ed machines files cp tuf /var/log/syslog /tmp --json
```

The last value is always the destination and the rest are sources. Fewer than
two values exits 1 with `give at least one source and a destination directory`.

The destination is listed before anything changes. A matching name is kept by
adding ` 2`, then ` 3`, while preserving the extension. `--dry-run` prints those
resolved targets. `--replace` previews every replacement and changes nothing
until `--yes` is also present.

What runs is `cp -a`, so a directory is copied whole and modes, ownership where
the account is allowed to set it, and timestamps are preserved. A confirmed
replacement copies to a unique staging name first, renames the old target to a
rollback name only after the copy succeeds, publishes the staged arrival, and
then removes the rollback. A failed publication restores the old target.

The command is capped at 300 seconds. Without `--json` the output names every
resolved source and destination. The batch stops at the first failed item so a
later success cannot hide its status. A non-zero exit on the machine exits 1
with that same description and whatever the machine printed:

```
$ ed machines files cp tuf /srv/a.conf /srv/locked
error: copied 1 into /srv/locked failed on Asus TUF 7: cp: cannot create regular file '/srv/locked/a.conf': Permission denied
```

`executed` distinguishes a preview from a completed copy. `items` is the same
resolved plan in both modes, so automation can preview and confirm exact paths.

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
