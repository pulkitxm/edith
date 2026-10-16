# `ed machines mount`

Hangs a machine's file system off a folder on this Mac, from `/` down. Finder
shows it as a disk and every local tool, an editor, `grep`, `rsync`, reads and
writes it in place.

```
ed machines mount <machine> [path] [--at <dir>] [--read-only] [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | string, required | none | Machine name, ssh alias, id or unambiguous prefix. |
| `[path]` | remote directory | `/`, the whole file system | What to mount. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--at` | local directory, `~` expanded | `~/Edith/<machine name>` | Where to mount it. |
| `--read-only` | flag | off | Mount it `ro`, so nothing local can write to the machine. |
| `--json` | flag | off | Emit JSON on stdout instead of the line. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

```
$ ed machines mount tuf
tuf:/  ->  /Users/pulkit/Edith/tuf
```

## `--json` shape

```json
{
  "machine": "Asus TUF 7",
  "mountPoint": "/Users/pulkit/Edith/tuf",
  "readOnly": false,
  "remotePath": "/",
  "source": "tuf:/"
}
```

## Examples

```
ed machines mount tuf
ed machines mount tuf /srv --read-only
ed machines mount tuf --at ~/mnt/tuf --json
ed machines tuf mount /var/log
```

## Behaviour notes

This needs an `sshfs` on this Mac, which Edith does not install:

```
$ ed machines mount tuf
error: sshfs is not installed on this Mac.
hint: install FUSE-T, which needs no kernel extension: brew install --cask macos-fuse-t/cask/fuse-t macos-fuse-t/cask/fuse-t-sshfs
```

Either FUSE works. FUSE-T is the one to reach for first because it is a user
space NFS server rather than a kernel extension, so it installs without loading
a kext, without Reduced Security on an Apple Silicon Mac, and without a restart.
macFUSE with `gromgit/fuse/sshfs-mac` works too, at the cost of approving a
kernel extension. Edith drives whichever `sshfs` is first on `PATH`, and it
tries the mount twice: once with the macFUSE-only options, `volname`,
`idmap=user`, `defer_permissions` and the Apple metadata switches, and then
without them, so an sshfs that rejects the first set still mounts.

The mount rides the same ControlMaster socket everything else on this page uses.
`ed` opens the connection first, then points `sshfs` at that socket with
`ControlPath`, `ControlMaster=no` and `BatchMode=yes`, so the mount is a second
channel on the connection already there and no password or passphrase is asked
for twice. The socket path is quoted inside the option, because it lives under
`Application Support` and `ssh` would otherwise stop at the space. Because it
never prompts, a mount attempted while the machine is unreachable fails rather
than hanging.

`sshfs` stays running as the mount's own process, so `ed` does not wait for it
to exit: it watches the mount table for up to 16 seconds and reports the mount
the moment it appears, or stops the process and reports what it printed.

Files show up owned by you: `idmap=user` maps the remote account to yours, and
`uid` and `gid` are this Mac's. The volume is named after the machine, so that
is the name in Finder's sidebar. `reconnect` is on, so the mount survives a
short network drop instead of turning into stale handles.

The default mount point is created if it is missing. A folder that already has
something in it is refused, and so is a machine that is already mounted and
answering, both exiting 1:

```
$ ed machines mount tuf
error: That machine is already mounted at /Users/pulkit/Edith/tuf.
```

A mount that is recorded but dead is the case this command repairs instead of
refusing. With no `path` and no `--at` it takes whatever is left down and mounts
again where it was, with the same remote path and the same read-only setting:

```
$ ed machines mounts
MACHINE     REMOTE  AT                       MODE  STATE
Asus TUF 7  /       /Users/pulkit/Edith/tuf  rw    gone

$ ed machines mount tuf
remounted tuf:/  ->  /Users/pulkit/Edith/tuf
```

Naming a `path` or an `--at` turns that off, because then you are asking for a
different mount rather than for the one that broke.

The default is the whole file system, so `~/Edith/tuf/etc/hosts` is the
machine's `/etc/hosts`. Mounting one directory instead is the same command with
a path, and `--read-only` is worth having on anything you only meant to read: a
mounted machine is as easy to delete from as a local disk, root included.

The mount belongs to the login session, not to Edith. It stays up when Edith
quits, and it goes away on logout or restart. `ed machines disconnect` closes
the control socket; the mount then keeps itself alive on its own connection.

What Edith keeps is a small record in
`~/Library/Application Support/Edith/machines/mounts.json`, one line per mount
it made: the machine, the remote path and the mount point. That is what ties a
mount back to a machine, because not every FUSE reports the `user@host:/path`
source in the mount table, and it is what a repair puts back.

**When the connection goes.** A mount is its own `sshfs` process rather than a
channel on the shared connection, so a dropped master does not take it down and
`-o reconnect` rides out a short network blip on its own. What it does not
survive is the machine sleeping or rebooting, or the process being killed: the
mount either disappears or turns into a folder that hangs when you touch it.
Both are named by the state in `ed machines mounts`, and both are repaired the
same way, by taking whatever is left down and mounting again from the record.

Three things trigger the repair. The app checks every machine it is connected to
every 20 seconds, and again after this Mac wakes, which is the same shape the
port forward replay has. `ed machines mount <machine>` with no path repairs
rather than refusing, and says `remounted` when it did. Opening the machine's
Tools tab checks once on the spot, and the dot beside the mount point says
whether it is answering.

Nothing repairs a mount you took down yourself: `ed machines unmount` and the
Unmount button both drop the record, and a mount with no record is left alone.
That also means a mount you drop with a bare `umount` behind Edith's back comes
back on the next check, because from here it looks exactly like a mount that
died. Use `ed machines unmount` when you mean it.

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
