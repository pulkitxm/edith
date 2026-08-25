# `ed machines files mv`

Moves one or more paths into a directory on the machine. This is the window's
cut and paste.

```
ed machines files mv <machine> <path>... <directory> [--dry-run] [--replace] [--yes] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Which machine. |
| `path...` | one or more remote paths, then the destination directory last | at least two values required | What to move, and where to. |
| `--dry-run` | flag | off | Print the exact resolved destinations without moving. |
| `--replace` | flag | off | Target an existing matching name instead of making a numbered move. |
| `--yes` | flag | off | Confirm replacements requested with `--replace`. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "operation": "machines.files.move-within-machine",
  "machine": "Asus TUF 7",
  "destination": "/home/pulkit/archive",
  "dryRun": false,
  "executed": false,
  "requiresConfirmation": true,
  "items": [{
    "source": "/home/pulkit/old.log",
    "destination": "/home/pulkit/archive/old.log",
    "replacesExisting": true
  }],
  "skipped": []
}
```

```
ed machines files mv tuf /home/pulkit/old.log /home/pulkit/archive
ed machines files mv tuf /srv/a.conf /srv/b.conf /srv/old
ed machines files mv tuf /tmp/build /srv/releases --json
```

The collision policy is identical to `cp`: matching names get a numbered target
by default, `--dry-run` prints the plan, and `--replace` needs `--yes` before it
can remove anything. A confirmed replacement first copies the source to a
unique staging area beside the target, renames the old target to a rollback
name, and then publishes the staged source. The original source is removed only
after publication succeeds. A failed publication restores the old target and
keeps the source. A batch stops at the first failed item.

Fewer than two values exits 1, a non-zero exit on the machine exits 1 with the
machine's message, and the command is capped at 300 seconds.

A move made here is not on any window's undo stack. Reverse it with another
`mv`, not with `ed machines files undo`.

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
