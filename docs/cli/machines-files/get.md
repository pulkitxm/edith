# `ed machines files get`

Downloads one file from the machine to this Mac.

```
ed machines files get <machine> <remote> [local] [--dry-run] [--replace] [--yes] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Which machine to read from. |
| `remote` | remote file path | required | The file to download. |
| `local` | local path, `~` expanded | the remote file's name, in the working directory | Where to write it. |
| `--dry-run` | flag | off | Print the exact local destination without downloading. |
| `--replace` | flag | off | Target an existing file instead of choosing a numbered name. |
| `--yes` | flag | off | Confirm replacement requested with `--replace`. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "operation": "machines.files.download",
  "sourceMachine": "Asus TUF 7",
  "destinationMachine": null,
  "destination": "/Users/pulkit",
  "dryRun": false,
  "executed": true,
  "requiresConfirmation": false,
  "items": [{
    "source": "/etc/os-release",
    "destination": "/Users/pulkit/os-release 2",
    "replacesExisting": false
  }],
  "skipped": [],
  "completed": [{
    "source": "/etc/os-release",
    "destination": "/Users/pulkit/os-release 2",
    "replacesExisting": false
  }],
  "failures": []
}
```

```
ed machines files get tuf /etc/os-release
ed machines files get tuf /var/log/syslog ~/Desktop/syslog.txt
ed machines files get tuf /etc/hosts --json
```

The destination directory is listed before the transfer. An existing name is
kept by adding ` 2`, then ` 3`, while preserving the extension. `--dry-run`
prints that resolved path. `--replace` previews a matching target and changes
nothing until `--yes` is also present.

The remote file first lands in an isolated staging directory, then a complete
copy is staged beside the local destination. A confirmed file replacement is
published atomically. Directory replacement keeps a rollback name until the new
file is in place. A failed download or publication preserves the old destination
and removes its new staging data.

The human output reports the resolved source and destination:

```
$ ed machines files get tuf /etc/os-release
downloaded 1 item(s)
  /etc/os-release -> /Users/pulkit/os-release 2
```

A remote path that does not exist, or one `cat` refuses such as a directory,
exits 1, and the half-written staging file is removed rather than left looking
complete:

```
$ ed machines files get tuf /etc/shadow
error: download failed: cat: /etc/shadow: Permission denied
```

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
