# `ed cleaner drives`

Lists the mounted volumes, largest internal first.

Usage:

```
ed cleaner drives [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments.

`--json` shape, an array with one object per volume:

```json
[
  {
    "external": false,
    "id": "/",
    "name": "Macintosh HD",
    "totalBytes": 494384795648
  }
]
```

`id` is the mount point, which is also what you would pass to `--root` to sweep
that volume. `name` is the volume name macOS reports, falling back to the last
path component. `totalBytes` is capacity, not free space; `ed system disks` is
where free space lives. `external` is true when the volume is removable or is
not an internal one, so a Thunderbolt SSD and a USB stick both read as
external.

Examples:

```
ed cleaner drives
ed cleaner drives --json
ed cleaner scan --root /Volumes/Backup
```

```
$ ed cleaner drives
NAME          MOUNT  SIZE    KIND
Macintosh HD  /      494 GB  internal
```

Behaviour: this enumerates mounted volumes and hides the hidden ones. It writes
nothing and needs nothing running. Ordering is internal volumes before external
ones, and within each group largest capacity first. Nothing else in the CLI
consumes this list: the app's drive picker stores a chosen set in
`cleanerSelectedDrives`, but `ed cleaner scan` and `ed cleaner clean` never read
that setting, so `drives` is here to tell you which mount point to hand to
`--root`.

## Where to go next

- [`ed cleaner`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
