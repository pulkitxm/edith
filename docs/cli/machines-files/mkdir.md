# `ed machines files mkdir`

Makes a directory on the machine.

```
ed machines files mkdir <machine> <path> [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Which machine. |
| `path` | remote directory path | required | The directory to make. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "done": true,
  "machine": "Asus TUF 7",
  "path": "/home/pulkit/backup/2026-08"
}
```

```
ed machines files mkdir tuf /home/pulkit/backup
ed machines files mkdir tuf /srv/releases/2026-08/staging
ed machines files mkdir tuf /tmp/work --json
```

What runs is `mkdir -p`, so missing parents are created in one go and a
directory that already exists is not an error: it prints `made <path>` and exits
0. A path the account cannot write exits 1 with the machine's message.

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
