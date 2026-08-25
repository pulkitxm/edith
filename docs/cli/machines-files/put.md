# `ed machines files put`

Uploads one file from this Mac to the machine.

```
ed machines files put <machine> <local> <remote> [--dry-run] [--replace] [--yes] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Which machine to write to. |
| `local` | local file path, `~` expanded | required | The file to upload. |
| `remote` | remote file path, or a directory | required | Where to put it. |
| `--dry-run` | flag | off | Print the exact remote destination without uploading. |
| `--replace` | flag | off | Target an existing file instead of choosing a numbered name. |
| `--yes` | flag | off | Confirm replacement requested with `--replace`. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "operation": "machines.files.upload-file",
  "sourceMachine": "This Mac",
  "destinationMachine": "Asus TUF 7",
  "destination": "/home/pulkit/uploads",
  "dryRun": true,
  "executed": false,
  "requiresConfirmation": false,
  "items": [{
    "source": "/Users/pulkit/clip.mov",
    "destination": "/home/pulkit/uploads/clip 2.mov",
    "replacesExisting": false
  }],
  "skipped": []
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
keeps the local filename; so does a path that passes a 20 second remote
file-kind probe as a directory. An existing file remains an exact file target,
including when an empty directory listing would otherwise look identical.

The directory is listed before upload. A matching name is kept by adding ` 2`,
then ` 3`, while preserving the extension. `--dry-run` prints the resolved
target. `--replace` previews an existing target and needs `--yes` to continue.

Uploads always use a unique staging path on the machine. A confirmed replacement
renames the old target to a unique backup only after the complete staged upload
succeeds. It then publishes the staged file and removes the backup. A failed
publication restores the backup, and a failed upload removes only its staging
path:

```
$ ed machines files put tuf ./clip.mov /tmp/no-such-dir/clip.mov
error: upload failed: bash: line 1: /tmp/no-such-dir/clip.mov: No such file or directory
```

The JSON `items` plan is identical before and after execution, so automation can
verify the exact destination before confirming a replacement.

This is a single-file transfer, because a directory has nothing to pipe into
`cat`. Send a tree with `ed tuf 'tar -xzf - -C /srv'` and a local `tar` on the
other end of the pipe, or copy it within the machine with `cp`.

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
