# `ed machines services start`

Starts one unit.

```
ed machines services start <machine> <unit> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias or id | required | Which machine the unit lives on. |
| `<unit>` | unit name | required | The unit, for example `nginx.service`. Quoted for the remote shell only when it holds something outside letters, digits and `._-+/=:@%,`, so a name with awkward characters survives. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the human line. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

```
$ ed machines services start tuf nginx.service
started nginx.service on Asus TUF 7
```

## `--json` shape

```json
{
  "action": "start",
  "applied": true,
  "machine": "Asus TUF 7",
  "unit": "nginx.service"
}
```

This document is only ever emitted on success. A failure writes nothing to
stdout and reports on stderr instead.

## Examples

```
ed machines services start tuf nginx.service
ed machines tuf services start docker.service
ed machines services start tuf nginx.service --json
```

## Behaviour notes

There is no `--yes` on the unit verbs. They act immediately.

The remote line for `nginx.service` is
`systemctl start nginx.service 2>&1 || sudo -n systemctl start nginx.service 2>&1`,
with a 60 second timeout. The unit is only wrapped in single quotes when it holds
a character outside letters, digits and `._-+/=:@%,`, so an ordinary name goes
across bare. Note the order: plain `systemctl` first, `sudo -n` as the fallback,
which is the opposite way round from `reboot` and `shutdown`.

When the machine has a sudo password stored, the two attempts collapse into one:
`sudo -S -p '' systemctl start nginx.service 2>&1`, with the password written to
the command's stdin rather than onto a command line, and no fallback afterwards
to leave stale text in the output. Store it with
`ed machines edit <machine> --sudo-password-stdin`, which is what makes these
verbs work on a stock desktop Linux where polkit treats an SSH session as
inactive and `sudo -n` refuses to prompt.

Systemd's own unit name shorthand applies, because `ed` passes the name straight
through: `nginx` and `nginx.service` are the same unit to `systemctl start`. The
`.service` suffix is what `ed machines services ls` prints, so it is the safe
thing to copy.

A failure exits 1 with the machine's output appended, and adds the sudo hint
only when the output looks like a privilege problem:

```
$ ed machines services start tuf nginx.service
error: could not start nginx.service on Asus TUF 7: Failed to start nginx.service: Unit nginx.service not found.
```

An unreachable machine exits 4 before the unit is touched. An unknown machine
name exits 3. A unit that does not exist is a remote failure, so it exits 1, not
3: `ed` never checks the unit list before acting.

## Where to go next

- [`ed machines power`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
