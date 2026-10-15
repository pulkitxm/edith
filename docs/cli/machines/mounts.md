# `ed machines mounts`

Lists every machine file system mounted on this Mac.

```
ed machines mounts [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the table. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

```
$ ed machines mounts
MACHINE     REMOTE  AT                       MODE  STATE
Asus TUF 7  /       /Users/pulkit/Edith/tuf  rw    mounted
pi          /srv    /Users/pulkit/Edith/pi   ro    gone
```

## `--json` shape

```json
[
  {
    "machine": "Asus TUF 7",
    "mountPoint": "/Users/pulkit/Edith/tuf",
    "readOnly": false,
    "remotePath": "/",
    "source": "tuf:/",
    "state": "mounted"
  }
]
```

## Examples

```
ed machines mounts
ed machines mounts --json | jq -r '.[].mountPoint'
```

## Behaviour notes

This reads `/sbin/mount` and reports what the system says is mounted, filtered
to the mounts Edith recorded plus any FUSE mount whose source reads
`user@host:/path`. A recorded mount that is no longer in the table is listed too
rather than hidden, because Edith still means to have it: that is the `gone`
state. `STATE` is `mounted` when a `stat` on the mount point answers within six
seconds, `stale` when the mount is there but does not answer, and `gone` when
it has vanished. The last two are what `ed machines mount <machine>` repairs. So a machine mounted by hand with `sshfs` shows up here too,
matched to a name by its target, and an entry Edith cannot match to a machine is
listed under that target instead. Nothing here dials a machine, so it answers
instantly and works with every machine asleep.

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
