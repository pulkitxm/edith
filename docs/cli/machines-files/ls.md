# `ed machines files ls`

Lists one remote directory. This is the default subcommand, so
`ed machines files tuf /var/log` works, and it is aliased `list`.

```
ed machines files ls <machine> [path] [--all] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Which machine to read. |
| `path` | remote directory | `.`, which means the login home directory | Directory to list. |
| `--all`, `-a` | flag | off | Include dotfiles. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "entries": [
    {
      "kind": "directory",
      "linkTarget": null,
      "mode": "755",
      "modified": "2026-08-04T18:22:07Z",
      "name": "uploads",
      "path": "/home/pulkit/uploads",
      "sizeBytes": 4096
    },
    {
      "kind": "file",
      "linkTarget": null,
      "mode": "644",
      "modified": "2026-08-06T09:14:52Z",
      "name": "deploy.sh",
      "path": "/home/pulkit/deploy.sh",
      "sizeBytes": 1842
    },
    {
      "kind": "symlink",
      "linkTarget": "/srv/app/current",
      "mode": "777",
      "modified": "2026-07-19T11:03:44Z",
      "name": "current",
      "path": "/home/pulkit/current",
      "sizeBytes": 16
    }
  ],
  "path": "/home/pulkit"
}
```

```
ed machines files ls tuf
ed machines files ls tuf /var/log --all
ed machines files ls tuf /etc --json
ed machines tuf files ls /srv
```

The default `path` is the literal string `.`, and `ed` turns that into the home
directory by asking the machine for `$HOME` first, falling back to `/` if it
answers nothing. Typing `.` yourself means the same thing, so there is no way to
say "the directory I was last in" here.

The listing itself is one `find -mindepth 1 -maxdepth 1 -printf` with a 45
second timeout, falling back to `ls -lAn --time-style=+%s` on a machine whose
`find` has no `-printf`. Dotfiles are always fetched and dropped locally when
`--all` is off, so the flag costs no extra round trip. Entries come back
directories first, then by name case-insensitively, which is the order the app's
pane uses.

`kind` is `directory`, `file`, `symlink` or `other`. `mode` is whatever the
machine printed: `755` from the `find` path, `drwxr-xr-x` from the fallback.
`modified` is ISO 8601, or `null` when the fallback ran and the timestamps were
not epochs. `linkTarget` is `null` for everything that is not a symlink.
`sizeBytes` for a directory is the directory entry's own size, usually 4096,
even though the human table leaves that column blank:

```
$ ed machines files ls tuf
T  MODE  SIZE    NAME
d  755           uploads
-  644   1.8 KB  deploy.sh
l  777   16 B    current
```

An empty directory prints the header row and exits 0. A path that does not
exist, or one the account cannot read, exits 1:

```
$ ed machines files ls tuf /root
error: could not read /root on Asus TUF 7
```

The hint is meant to carry the machine's own complaint, but both the `find` and
the fallback are run with their stderr discarded, so it arrives empty and the
reason is not reported. Ask the machine directly with `ed tuf ls -la /root` when
you need to know which of the two it was.

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
