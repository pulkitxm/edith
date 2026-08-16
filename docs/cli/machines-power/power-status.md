# `ed machines power status`

Says whether the machine has a live shared connection, what MAC address is
stored for it, and which of wake and reboot are possible right now. It is the
default subcommand of `power`, so `ed machines power tuf` runs it.

```
ed machines power status <machine> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias or id | required | Which machine to report on. Resolved by name, alias, id or unambiguous prefix. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the table. Long form only, there is no `-j`. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

One row, five columns:

```
$ ed machines power status tuf
MACHINE     CONNECTED  MAC                WAKE  REBOOT
Asus TUF 7  yes        04:42:1a:8d:2f:6c  yes   yes
```

`MAC` prints `-` when Edith has never learned one.

## `--json` shape

```json
{
  "canReboot": true,
  "canShutDown": true,
  "canWake": true,
  "connected": true,
  "macAddress": "04:42:1a:8d:2f:6c",
  "machine": "Asus TUF 7"
}
```

`machine` is the display name, not the id. `macAddress` is `null` rather than
missing when none is stored, and `canWake` is exactly `macAddress != null`.
`canReboot` and `canShutDown` are both copies of `connected`.

## Examples

```
ed machines power status tuf
ed machines power tuf
ed machines tuf power
ed machines power status tuf --json | jq -r '.canWake'
```

## Behaviour notes

This is the one command on the page that never touches the network. `connected`
is a local test: it looks for the ControlMaster socket file for that machine and
runs `ssh -S <socket> -O check` against it. A machine that is up and reachable
but has no open shared connection reports `connected: false`, which is `no` in
the table.

Read that as a promise about cost, not about capability. `canReboot: false`
means there is no open channel to reuse, not that a reboot would be refused:
`ed machines power reboot` opens its own connection when there is none. What it
does tell you is that the next command will pay for a fresh SSH handshake.

Nothing is mutated. The only failure is an unknown machine, which exits 3.

## Where to go next

- [`ed machines power`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
