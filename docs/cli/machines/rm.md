# `ed machines rm`

Forgets a machine and everything saved against it. `remove` is an accepted
alias.

```
ed machines rm <machine> [--yes] [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | string, required | none | Machine name, ssh alias, id or unambiguous prefix. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--yes` | flag | off | Actually remove it. Without this nothing is touched. |
| `--json` | flag | off | Emit JSON on stdout instead of the lines. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

Without `--yes` it reports what it would take with it, changes nothing, and
exits 0:

```
$ ed machines rm tuf
would remove Asus TUF 7, 1 forward(s) and 0 snippet(s)
nothing was removed; pass --yes to go ahead
```

The second line is on stderr. With `--yes` the output is one line,
`removed Asus TUF 7`.

## `--json` shape

The same four keys either way, with `removed` telling you which run this was:

```json
{
  "forwards": 1,
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
  "removed": false,
  "snippets": 0
}
```

`forwards` and `snippets` are counts of what goes with the machine, and they are
reported on the dry run so you can gate on them.

## Examples

```
ed machines rm shed
ed machines rm shed --json
ed machines rm shed --yes
```

## Behaviour notes

With `--yes` it removes the machine from `machines.json`, every forward whose
`machineID` is this machine from `forwards.json`, every machine-scoped snippet
from `snippets.json`, and both keychain items, password and passphrase. Then it
posts `machinesChanged`.

Shared snippets survive, because they belong to every machine rather than to
this one. That is also why the `snippets` count here can be lower than what
`ed machines snippets ls` shows for the same machine: this counts only the ones
that die with it.

The control socket file is left where it is. It is named from the machine's id
and nothing else claims that name, so it is harmless; `ed machines disconnect`
before removing if you want it gone.

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
