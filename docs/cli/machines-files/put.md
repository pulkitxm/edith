# `ed machines files put`

Uploads one file from this Mac to the machine.

```
ed machines files put <machine> <local> <remote> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Which machine to write to. |
| `local` | local file path, `~` expanded | required | The file to upload. |
| `remote` | remote file path, or a directory | required | Where to put it. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "local": "/Users/pulkit/clip.mov",
  "remote": "/home/pulkit/uploads/clip.mov",
  "sizeBytes": 38109184
}
```

```
ed machines files put tuf ./deploy.sh /tmp/deploy.sh
ed machines files put tuf ./clip.mov /home/pulkit/uploads/
ed machines files put tuf ~/notes.md /srv/notes.md --json
```

The local file is checked before the machine is dialled, so a typo there exits 3
with `no file at /Users/pulkit/deploy.sh` and costs nothing.

The destination takes a directory as well as a file path. A path ending in `/`
keeps the local filename; so does a path that turns out to be a directory, which
`ed` establishes with a `test -d` probe capped at 20 seconds; anything else is
used verbatim. An empty destination becomes `/` plus the filename.

Once the destination is settled the same meter `get` prints appears on stderr,
counting the bytes sent against the local file's size, which `ed` reads here
rather than asking the machine for:

```
$ ed machines files put tuf ./clip.mov /home/pulkit/uploads/
  ⠸ clip.mov  9.7 MB of 38.1 MB  25% 6s
```

It follows the same rules as it does on `get`: terminal only, suppressed by
`--json`, and cleared when the transfer ends or fails.

The upload is `cat > <remote>`, streamed 128 KB at a time, and then it is
checked rather than assumed. The bytes sent must match the local file's size,
and the file's size on the machine, read back with `stat`, must match the bytes
sent. Any mismatch, a write the machine stopped accepting, or a non-zero exit
runs `rm -f` on the destination and exits 1:

```
$ ed machines files put tuf ./clip.mov /tmp/no-such-dir/clip.mov
error: upload failed: bash: line 1: /tmp/no-such-dir/clip.mov: No such file or directory
```

That cleanup is unconditional, which is the sharp edge of this command: an
upload that fails while overwriting an existing remote file removes the old file
too. `sizeBytes` in the JSON is the local file's size.

This is a single-file transfer, because a directory has nothing to pipe into
`cat`. Send a tree with `ed tuf 'tar -xzf - -C /srv'` and a local `tar` on the
other end of the pipe, or copy it within the machine with `cp`.

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
