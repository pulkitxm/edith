# `ed machines kill`

Sends a signal to one process on a machine.

```
ed machines kill <machine> <pid> [--signal <name>] [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias or id | required | Which machine the process is on. |
| `<pid>` | integer greater than 0 | required | The process id. A value that is not an integer exits 2; zero or negative exits 1. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--signal` | `TERM`, `KILL`, `HUP`, `INT`, `QUIT`, `USR1`, `USR2` | `TERM` | Which signal to send. Case-insensitive, and a leading `SIG` is stripped, so `kill`, `KILL`, `sigkill` and `SIGKILL` are all the same. Anything else exits 3. |
| `--json` | flag | off | Emit JSON on stdout instead of the human line. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

```
$ ed machines kill tuf 4213
sent SIGTERM to 4213 on Asus TUF 7
```

## `--json` shape

```json
{
  "alreadyExited": false,
  "machine": "Asus TUF 7",
  "pid": 4213,
  "sent": true,
  "signal": "KILL"
}
```

`signal` is the normalised name without the `SIG` prefix, whatever you typed.
`sent: true` means the remote `kill` exited 0; it is not a claim that the
process is gone, which for `TERM` is up to the process. `alreadyExited: true`
means the pid was not there to signal, and then `sent` is `false`.

## Examples

```
ed machines kill tuf 4213
ed machines kill tuf 4213 --signal KILL
ed machines tuf kill 4213 --signal HUP
ed machines metrics tuf --processes 20 --json | jq -r '.sample.processes[] | "\(.pid) \(.name)"'
```

## Behaviour notes

`ed machines metrics <machine> --processes 20` is how you find the pid; the
collector sends at most thirty processes, the busiest by CPU plus the largest by
memory, in no particular order, and `--processes` trims that list rather than
asking for more. There is no name matching here on purpose: this verb takes a
number, so it cannot kill the wrong thing because two processes shared a name.

The signal name is checked on this Mac before anything is sent, so a typo costs
nothing and never reaches the remote shell:

```
$ ed machines kill tuf 4213 --signal BOOM
error: there is no signal called BOOM
hint: signals: TERM, KILL, HUP, INT, QUIT, USR1, USR2
```

The remote line checks the pid is still there with `kill -0` and `/proc` before
it sends anything, then runs `kill -<SIGNAL> <pid> 2>&1`, through the login shell
with a 30 second timeout, so it runs as the SSH user and is subject to that
user's permissions. There is no sudo fallback here, unlike the unit verbs:
signalling another user's process comes back as `Operation not permitted` and
exits 1.

```
$ ed machines kill tuf 1
error: could not signal 1 on Asus TUF 7: bash: line 1: kill: (1) - Operation not permitted
```

A pid that is already gone is not a failure, because the process list a pid comes
from is a two second old snapshot and short lived processes routinely leave
between the sample and the signal. It exits 0 and says so, rather than passing
the shell's `No such process` on:

```
$ ed machines kill tuf 205886
205886 had already exited on Asus TUF 7
```

Zero and negative ids are rejected
locally with `a process id is greater than zero` and exit 1, though a negative
one needs `--` to get past the parser at all: a bare `ed machines kill tuf -1`
reads `-1` as an unknown option and exits 2, while `ed machines kill tuf -- -1`
reaches the check and exits 1.

## Where to go next

- [`ed machines power`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
