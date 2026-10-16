# `ed machines show`

One machine, with live facts. It opens the shared connection, then runs three
commands there: `uname -srm`, `uptime` and `who | head -20`.

```
ed machines show <machine> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | string, required | none | Machine name, ssh alias, id, or any unambiguous prefix of a name or alias, case-insensitively. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the indented block. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

```
$ ed machines show tuf
Asus TUF 7
  target   tuf · pulkit@192.168.1.12
  auth     SSH agent
  system   Linux 7.0.0-28-generic x86_64
  uptime   22:19:53 up  9:11,  5 users,  load average: 0.19, 0.16, 0.28
  session  pulkit on seat0 since 2026-08-08 13:08 (login screen)
  session  pulkit on tty2 since 2026-08-08 13:08 (tty2)
```

## `--json` shape

Four keys, always all four:

```json
{
  "machine": {
    "auth": "SSH agent",
    "connected": true,
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
  },
  "sessions": [
    "pulkit on seat0 since 2026-08-08 13:08 (login screen)",
    "pulkit on tty2 since 2026-08-08 13:08 (tty2)"
  ],
  "uname": "Linux 7.0.0-28-generic x86_64",
  "uptime": "22:18:08 up  9:10,  5 users,  load average: 0.07, 0.13, 0.30"
}
```

`machine` is the record described above. `uname` and `uptime` are the remote
command's stdout, trimmed, and `sessions` is `who` reformatted one entry per
line as `<user> on <tty> since <the rest of the line>`; a `who` line with fewer
than three fields is dropped rather than guessed at.

## Examples

```
ed machines show tuf
ed machines tuf
ed tuf
ed machines show tuf --json | jq -r .uname
```

## Behaviour notes

Nothing is written to the directory, but the command does open the shared
connection when one is not already up, which leaves a socket behind for the next
command.

Each of the three remote commands is best effort with its own timeout: 20
seconds for `uname`, 15 each for `uptime` and `who`. A command that fails or
times out contributes an empty string rather than failing the whole report,
which is why a machine with no `who` still prints its `uname` line.

An unknown or ambiguous name exits 3 before anything is dialled. A machine that
cannot be reached exits 4 and says why, in ssh's words.

`ed machines <machine>` with nothing after it, and `ed <machine>` with nothing
after it, are both rewritten to this command. See
[running commands on a machine](../machines-remote/README.md).

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
