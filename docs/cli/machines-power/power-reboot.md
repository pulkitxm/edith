# `ed machines power reboot`

Restarts the machine through systemd. Does nothing without `--yes`.

```
ed machines power reboot <machine> [--yes] [--json]
```

The command is also spelled `ed machines power restart`.

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias or id | required | Which machine to restart. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--yes` | flag | off | Actually restart it. Without this nothing is done. |
| `--json` | flag | off | Emit JSON on stdout instead of the human lines. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

Without `--yes` it tells you what it would do, changes nothing, and exits 0. The
line naming the machine goes to stdout and the reminder goes to stderr:

```
$ ed machines power reboot tuf
would restart Asus TUF 7
nothing was done; pass --yes to go ahead
```

With `--yes` it connects, runs the reboot, and reports:

```
$ ed machines power reboot tuf --yes
Asus TUF 7 is restarting
```

## `--json` shape

Two shapes, told apart by `applied`. Without `--yes` the document also carries
the exact shell line that would have run, so you can read it before you run it:

```json
{
  "action": "reboot",
  "applied": false,
  "command": "sudo -n systemctl reboot 2>&1 || systemctl reboot 2>&1",
  "machine": "Asus TUF 7"
}
```

With `--yes`, on success, `command` is not included:

```json
{
  "action": "reboot",
  "applied": true,
  "machine": "Asus TUF 7"
}
```

`action` is the literal string `reboot` in both, even when you typed the
`restart` alias.

## Examples

```
ed machines power reboot tuf
ed machines power reboot tuf --yes
ed machines tuf power reboot --yes
ed machines power restart tuf --yes --json
```

## Behaviour notes

The remote line is `sudo -n systemctl reboot 2>&1 || systemctl reboot 2>&1`, so
`ed` tries passwordless sudo first and falls back to plain `systemctl` for a
machine whose polkit rules already allow it. Stderr is folded into stdout on the
far side, which is why a refusal comes back as readable prose rather than as an
empty failure.

When the machine has a sudo password stored, the line is
`sudo -S -p '' systemctl reboot 2>&1` instead, with the password written to the
command's standard input rather than put on the command line, and there is no
fallback: one attempt, and a wrong password is reported as one. Store it with
`ed machines edit <machine> --sudo-password-stdin`. This is the way that works on
a stock desktop Linux, where polkit treats an SSH session as inactive and refuses
`systemctl poweroff` without interactive authentication.

A machine that answers *a password is required* or *Interactive authentication
required* is reported as having refused, and exits 1, rather than being called
done. The hint appears only when the output matches one of the phrases that mean
privilege: `password is required`, `interactive authentication required`,
`access denied`, `not authorized` or `permission denied`.

```
$ ed machines power reboot tuf --yes
error: Asus TUF 7 did not reboot: sudo: a password is required
Call to Reboot failed: Interactive authentication required.
hint: give this account passwordless sudo for systemctl on Asus TUF 7
```

The error text after the colon is the machine's own combined output, trimmed.
When the machine said nothing at all that half falls back to a second sentence
of Edith's own, so the whole line reads
`error: Asus TUF 7 did not reboot: Asus TUF 7 refused to reboot`.

The command waits at most 20 seconds for the remote line to return. Reaching the
machine happens first and has its own 25 second budget; a machine that cannot be
reached exits 4 with `could not reach <machine>` before anything is attempted.

`systemctl reboot` returns as soon as systemd accepts the request, which is why
the usual successful run exits cleanly before the host disappears. If ssh
instead exits non-zero because the connection died under it, that is reported as
a refusal and exits 1; see the gotcha at the end of this page.

## Where to go next

- [`ed machines power`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
