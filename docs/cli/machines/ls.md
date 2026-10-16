# `ed machines ls`

Lists every configured machine. It is the default subcommand, so `ed machines`
on its own runs it, and `list` is an accepted alias.

```
ed machines ls [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the table. Long form only, there is no `-j`. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

Four columns, one row per machine, in the order they appear in `machines.json`,
which is the order they were added. Nothing is sorted:

```
$ ed machines ls
NAME        TARGET                     AUTH       STATE
Asus TUF 7  tuf · pulkit@192.168.1.12  SSH agent  connected
```

STATE is `connected` when the ControlMaster socket answers, and `-` when it does
not. With no machines configured, stdout stays empty, stderr carries
`no machines are configured; add one in Edith under Machines`, and the exit code
is 0.

## `--json` shape

A top-level array of machine records, empty when nothing is configured:

```json
[
  {
    "auth": "SSH agent",
    "connected": false,
    "controlSocket": "/Users/pulkit/Library/Application Support/Edith/machines/sockets/4303DCF152.sk",
    "createdAt": "2026-08-06T12:11:49Z",
    "host": "192.168.1.12",
    "id": "4303DCF1-52D8-4075-AE9B-C2FD86D3821A",
    "name": "Asus TUF 7",
    "port": 22,
    "source": "sshConfigAlias",
    "sshAlias": "tuf",
    "sshTarget": "tuf",
    "username": "pulkit",
    "wakeMACAddress": "be:f0:86:8d:58:12"
  }
]
```

## Examples

```
ed machines ls
ed machines ls --json
ed machines ls --json | jq -r '.[] | select(.connected) | .name'
```

## Behaviour notes

Read only. It reads one file and dials nothing, so an unreachable machine still
appears, with STATE `-`. The one cost is the `connected` field: for every
machine whose socket file exists, `ed` runs `ssh -S <socket> -O check <target>`,
so a directory of twenty connected machines is twenty short subprocesses. A
machine with no socket file is answered from the filesystem alone.

This is one of the handful of commands that does not run inside the CLI's
failure wrapper. Nothing observable changes; the top level reports and codes a
failure identically.

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
