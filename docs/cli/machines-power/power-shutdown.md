# `ed machines power shutdown`

Powers the machine off through systemd. Does nothing without `--yes`.

```
ed machines power shutdown <machine> [--yes] [--json]
```

The command is also spelled `ed machines power poweroff`.

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias or id | required | Which machine to shut down. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--yes` | flag | off | Actually shut it down. Without this nothing is done. |
| `--json` | flag | off | Emit JSON on stdout instead of the human lines. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

```
$ ed machines power shutdown tuf
would shut Asus TUF 7 down
nothing was done; pass --yes to go ahead

$ ed machines power shutdown tuf --yes
Asus TUF 7 is shutting down
```

## `--json` shape

The same two shapes as `reboot`, with `action` set to `shutdown` and the remote
line built from `poweroff`:

```json
{
  "action": "shutdown",
  "applied": false,
  "command": "sudo -n systemctl poweroff 2>&1 || systemctl poweroff 2>&1",
  "machine": "Asus TUF 7"
}
```

```json
{
  "action": "shutdown",
  "applied": true,
  "machine": "Asus TUF 7"
}
```

## Examples

```
ed machines power shutdown tuf
ed machines power shutdown tuf --yes
ed machines tuf power poweroff --yes
ed machines power shutdown tuf --json
```

## Behaviour notes

Identical to `reboot` in every respect but the verb: same 20 second timeout,
same sudo-then-plain fallback, same refusal detection, same exit codes.

Think about the way back before you run it. A machine that is off answers
nothing, so the only verb left is `ed machines power wake`, and that needs a
stored MAC address and a machine whose firmware has wake-on-LAN enabled. Check
with `ed machines power status <machine>` first: if `WAKE` says `no`, a shutdown
is a trip to the physical power button.

## Where to go next

- [`ed machines power`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
