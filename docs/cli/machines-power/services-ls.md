# `ed machines services ls`

Lists the systemd service units on a machine. It is the default subcommand of
`services`, so `ed machines services tuf` runs it. Also spelled
`ed machines services list`.

```
ed machines services ls <machine> [--failed] [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias or id | required | Which machine to list units on. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--failed` | flag | off | Only failed units, meaning those whose `active` or `sub` field is `failed`. Filtered on this Mac after the full list arrives. |
| `--json` | flag | off | Emit JSON on stdout instead of the table. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

```
$ ed machines services tuf
UNIT                       ACTIVE  SUB      WHAT
cron.service               active  running  Regular background program processing daemon
docker.service             active  running  Docker Application Container Engine
nginx.service              active  running  A high performance web server
ollama.service             failed  failed   Ollama Service
ssh.service                active  running  OpenBSD Secure Shell server
systemd-timesyncd.service  active  running  Network Time Synchronization
```

## `--json` shape

A top-level array, one object per unit, in the order `systemctl` returned them:

```json
[
  {
    "active": "active",
    "description": "A high performance web server",
    "failed": false,
    "load": "loaded",
    "running": true,
    "sub": "running",
    "unit": "nginx.service"
  },
  {
    "active": "failed",
    "description": "Ollama Service",
    "failed": true,
    "load": "loaded",
    "running": false,
    "sub": "failed",
    "unit": "ollama.service"
  }
]
```

`load`, `active` and `sub` are systemd's own three columns, passed through
untouched. `running` is `sub == "running"` and `failed` is
`active == "failed" || sub == "failed"`, both precomputed so a script does not
have to know systemd's vocabulary. The JSON key is `description`; the table
column is headed `WHAT`.

## Examples

```
ed machines services tuf
ed machines services ls tuf --failed
ed machines tuf services ls
ed machines services ls tuf --json | jq -r '.[] | select(.failed) | .unit'
```

## Behaviour notes

The remote line is this, with a 30 second timeout:

```
systemctl list-units --type=service --all --no-pager --no-legend --plain 2>/dev/null | head -200
```

Three consequences worth knowing.

The list is capped at 200 units and there is no flag to raise it. A machine with
more services than that loses the tail silently.

Only `.service` units are listed. Timers, sockets, mounts and targets are not,
because the parser drops any line whose first field does not end in `.service`.

A machine with no systemd at all reports nothing rather than failing. The
`2>/dev/null` swallows the "command not found" and `head` exits 0, so you get a
note on stderr and exit 0:

```
$ ed machines services ls box
no systemd units reported
```

`--failed` narrows the list here, on this Mac, after all 200 lines have crossed
the wire. It is not `systemctl --failed`, so it costs the same as the full list.

## Where to go next

- [`ed machines power`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
