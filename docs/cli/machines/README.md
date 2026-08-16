# `ed machines`

`ed machines` is the directory of computers Edith can reach over SSH, and the
verbs that keep it: list them, inspect one, add, rename, remove, open and close
the shared connection, sample a machine's load, run a command there, and keep
the saved port forwards and command snippets each machine offers.

The directory is three JSON files under
`~/Library/Application Support/Edith/machines`: `machines.json`,
`forwards.json` and `snippets.json`. Passwords and key passphrases live in the
login keychain, never in those files. Nothing here talks to the Edith app, so
every command on this page works whether or not Edith is running; every
mutation posts the same `machinesChanged` notification the app posts to itself,
so an open Machines window updates immediately when it is there to hear it.

Transport is `/usr/bin/ssh` over a ControlMaster socket shared with the app. If
the app already holds a connection, `ed` lands on it and the command is one
round trip on an open channel. If it does not, `ed` opens one, and
`ControlPersist=10m` keeps that socket alive for ten idle minutes so the next
command is fast. `ed machines disconnect` closes it early.

## Resource behaviour

The app keeps one metrics stream per connected remote machine. That stream
samples every two seconds and sends one record back over the shared SSH
connection. It does not open a new SSH process for every measurement. The
remote collector reads the block-device list once when it starts and obtains
the process list with one `ps` invocation per sample. CPU and memory details for
the selected processes still come from `/proc`, so the values retain their
per-process accuracy without launching a command for every row.

Local monitoring also samples every two seconds, but the more expensive process
table is refreshed every fifth sample and reused between refreshes. Each sample
updates the current metrics and all six chart histories as one published value,
so one machine sample causes one metrics view update.

Connection health uses a 30 second latency probe while a connection is healthy.
The shared socket is checked separately only after a failed probe or a wake
event. Docker container state refreshes every 30 seconds in the background and
every four seconds while a Docker window is visible. Opening the window or
performing an action still refreshes immediately. Overlapping container and
inventory refreshes are coalesced into one run.

Long-running stdout and stderr readers unregister when they reach end of file,
and completed SSH commands cancel their pending timeout work. A new connection
waits for its fresh control socket instead of repeatedly launching `ssh -O
check` while the master is starting. Streaming CLI commands suspend until the
SSH process reports completion or the command is cancelled. They do not poll
the process state between metric records.

## At a glance

| Command | What it does |
| --- | --- |
| `ed machines ls` | Lists every configured machine with its target, auth method and whether the shared connection is open. Runs when you type `ed machines` with no subcommand. |
| `ed machines show` | One machine: the stored record plus a live `uname`, `uptime` and login list. |
| `ed machines add` | Adds a machine to the directory, optionally storing a password or key passphrase from stdin. |
| `ed machines edit` | Changes a machine already on the list: name, host, port, user, auth, wake address. |
| `ed machines rm` | Forgets a machine, its forwards, its machine-scoped snippets and its keychain entries. |
| `ed machines forwards ls` | Lists the port forwards saved for a machine, numbered from 1. |
| `ed machines forwards add` | Saves a port forward. Does not open it. |
| `ed machines forwards rm` | Forgets one saved forward. |
| `ed machines forwards on` | Opens a saved forward on the shared connection. |
| `ed machines forwards off` | Closes a saved forward. |
| `ed machines snippets ls` | Lists the snippets a machine offers, its own and the shared ones. |
| `ed machines snippets add` | Saves a command against one machine, or against every machine with `--shared`. |
| `ed machines snippets rm` | Forgets one snippet. |
| `ed machines metrics` | Samples CPU, memory, load, disk and network on a machine, once or continuously. |
| `ed machines exec` | Runs a command there, passing both streams and the remote exit code through. |
| `ed machines connect` | Opens the shared SSH connection and reports the round trip time. |
| `ed machines disconnect` | Closes the shared SSH connection and removes its socket. |
| `ed machines mount` | Mounts a machine's whole file system on this Mac, so Finder and every local tool can read it. Run again to put a dead mount back. |
| `ed machines unmount` | Unmounts it again and tidies the folder away. Aliased `umount`. |
| `ed machines mounts` | Lists every machine file system Edith mounted or can see, and whether each one still answers. |

Eight more subcommands live under `ed machines` and are documented on five
further pages: [`docker`](../machines-docker/README.md), [`files`](../machines-files/README.md),
[`power`](../machines-power/README.md), [`services`](../machines-power/README.md),
[`kill`](../machines-power/README.md), [`broadcast`](../machines-power/README.md),
[`thermal`](../machines-thermal/README.md) and [`workspace`](../machines-workspace/README.md).

## The machine record

Every command that reports a machine reports the same object, built by one
function, so `ls`, `show`, `add`, `edit` and `rm` cannot disagree about a field.
Nine of these are stored in `machines.json`; four are derived on every read.

| Field | Type | Stored? | What it is |
| --- | --- | --- | --- |
| `id` | string, uppercase UUID | stored | The machine's identity. Stable across renames, and what forwards, snippets, keychain items, the control socket and the remembered working directory are keyed by. |
| `name` | string | stored | What you call it. Unique, case-insensitively, across the directory. |
| `host` | string | stored | Hostname or address. May be empty for a machine that came from your `ssh config`. |
| `port` | integer, 1 to 65535 | stored | SSH port. `22` unless you set another. |
| `username` | string, may be empty | stored | Who to log in as. Empty means ssh decides, which is your local user unless `ssh config` says otherwise. |
| `auth` | `"SSH agent"`, `"Key file"` or `"Password"` | stored | How the connection authenticates. The key path and the "has a passphrase" flag are stored with it but are not reported. |
| `source` | `"manual"` or `"sshConfigAlias"` | stored | Whether you typed the host or picked an entry out of your `ssh config`. |
| `sshAlias` | string or `null` | derived | The `ssh config` alias when `source` is `sshConfigAlias`, `null` when it is `manual`. It is projected out of `source`, not a field of its own. |
| `wakeMACAddress` | string or `null` | stored | The MAC address `ed machines power wake` sends its magic packet to. Edith learns it the first time it sees the machine up. |
| `createdAt` | ISO 8601 timestamp | stored | When the machine was added. |
| `sshTarget` | string | derived | What is handed to `ssh`: the alias for an `ssh config` machine, otherwise `user@host`, or bare `host` when `username` is empty. |
| `controlSocket` | absolute path | derived | The ControlMaster socket for this machine, named from the first ten hex digits of `id` with a `.sk` suffix. |
| `connected` | boolean | derived | Whether that socket exists and answers `ssh -O check` right now. |

```json
{
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
}
```

The human output has one more derived string, the TARGET column, which the app
calls the machine's subtitle. For a manual machine it is `user@host`, with
`:port` appended when the port is not 22. For an `ssh config` machine it is the
alias, followed by ` · user@host` when the resolved target differs from the
alias.

A stored password or passphrase is not part of the record and no command prints
it. It lives in the login keychain under service `com.pulkit.edith.machines`,
account `<id>.password` or `<id>.passphrase`, which is the same item the app
reads and writes.

## Commands

- [`ed machines ls`](./ls.md)
- [`ed machines show`](./show.md)
- [`ed machines add`](./add.md)
- [`ed machines edit`](./edit.md)
- [`ed machines rm`](./rm.md)
- [`ed machines forwards ls`](./forwards-ls.md)
- [`ed machines forwards add`](./forwards-add.md)
- [`ed machines forwards rm`](./forwards-rm.md)
- [`ed machines forwards on`](./forwards-on.md)
- [`ed machines forwards off`](./forwards-off.md)
- [`ed machines snippets ls`](./snippets-ls.md)
- [`ed machines snippets add`](./snippets-add.md)
- [`ed machines snippets rm`](./snippets-rm.md)
- [`ed machines metrics`](./metrics.md)
- [`ed machines exec`](./exec.md)
- [`ed machines connect`](./connect.md)
- [`ed machines disconnect`](./disconnect.md)
- [`ed machines mount`](./mount.md)
- [`ed machines unmount`](./unmount.md)
- [`ed machines mounts`](./mounts.md)

## Exit codes

| Code | When |
| --- | --- |
| 0 | The command did what it says. A dry-run `rm` without `--yes`, an empty listing, and closing a forward that was not open all count as success. `--help` exits 0 too. |
| 1 | A duplicate machine name, a port outside 1 to 65535, `--agent` with `--key`, both stdin secret flags together, `--key-passphrase-stdin` without `--key` on `add`, no secret on stdin, a duplicate local port on `forwards add`, ssh refusing to open a forward, an empty snippet command, an empty `exec` command line, a `cd` to a path that does not exist, or a missing collector script. |
| 2 | The command line was wrong: an unknown flag, a missing `<machine>`, a missing `--host` on `add`, `--interval 0` or negative, or `--processes=-1`. |
| 3 | The thing you named does not exist: no machines configured at all, no machine by that name, a prefix that matches more than one machine, a `--key` path with no file, or a forward or snippet index outside the range. |
| 4 | The machine could not be reached, or it connected but never reported a metrics sample. |

`ed machines exec` is the exception, and deliberately so: it propagates the
remote command's own exit code, so any value from 0 to 255 can come back and
none of them mean what the table above says.

Nothing on this page needs the Edith app, so no command here exits 4 because the
app is closed.

## Notes and gotchas

- Names are forgiving and resolve in one fixed order: an exact name match, then
  an exact `ssh config` alias match, then the id, then a unique prefix of a name
  or alias. Every step is case-insensitive. A prefix matching more than one
  machine fails with the list of matches rather than guessing; an unknown name
  fails with the list of known machines. Both exit 3, and both hints end with
  every `ed machines` subcommand name.
- A subcommand name always wins over a machine name. A machine literally called
  `docker`, `ls` or `power` has to be named explicitly with
  `ed machines show docker`, and the error hint lists every subcommand name so
  you can see the collision.
- The machine name comes first, subject then verb: `ed machines tuf metrics`,
  `ed machines tuf files ls /etc`. The older order with the machine last,
  `ed machines metrics tuf`, still parses. `ed <machine> ...` is shorthand for
  `ed machines <machine> ...`, and `ed <machine>` alone is
  `ed machines show <machine>`.
- Every mutation posts `com.pulkit.edith.machinesChanged` on the distributed
  notification centre. That is fire and forget: nothing waits for a reply, and
  posting with Edith closed is harmless.
- The `machines` extension, the switch that decides whether the app shows the
  Machines tab, is never consulted by `ed`. These commands work with every
  extension turned off.
- Indexes are positions in a listing, not identities. Removing a forward or a
  snippet renumbers everything after it, so read the list again between two
  deletes rather than counting down.
- `forwards add` and `snippets add` both report `"index": 0` in JSON, because
  the number only means something in a listing. Follow with the matching `ls` if
  you need the position.
- Forwards are ordered by local port ascending. Snippets are in the order they
  were saved, with shared ones interleaved.
- Connection settings are the same on every command: host keys are checked
  against Edith's own `known_hosts` in the machines folder and yours in
  `~/.ssh/known_hosts`, with `StrictHostKeyChecking=accept-new`, so a new
  machine is trusted on first sight and a changed key is refused with a specific
  message. `ConnectTimeout` is 12 seconds, keepalives go every 15 seconds and
  give up after three.
- The control socket path is derived from the machine's id, the first ten hex
  digits with the dashes removed, plus `.sk`, under
  `~/Library/Application Support/Edith/machines/sockets`. It is reported as
  `controlSocket` on every machine record, which is what makes the app and `ed`
  share one connection.
- A stored password or passphrase is handed to ssh through `SSH_ASKPASS`, which
  points back at the `ed` binary itself with the keychain account in the
  environment. The secret never appears on a command line, and a host key
  confirmation prompt is answered by declining rather than by leaking it.
- An `ssh config` machine is dialled by alias alone. Its `port`, `username` and
  key are on the record and shown in the listing, but ssh never sees them;
  `~/.ssh/config` decides. Edit that file, not the machine, when an alias
  connects to the wrong place.
- Object keys are sorted in the JSON, in both the pretty and the compact form,
  so two runs diff cleanly. Every command here prints exactly one document
  except `metrics --follow --json`, which prints one compact document per line
  until interrupted.
- `ed machines ls` and `ed machines show` are the cheap way to learn the exact
  names every other command wants. Both take `--json`.

## Where to go next

- [Running commands on a machine](../machines-remote/README.md) for the `ed <machine>`
  shorthand, the remembered working directory and remote completion.
- [`ed machines files`](../machines-files/README.md) for browsing, transfers and the
  Finder window's operations.
- [`ed machines docker`](../machines-docker/README.md) for containers, images, volumes
  and compose projects.
- [`ed machines power`](../machines-power/README.md) for power state, systemd units,
  processes and `broadcast`.
- [`ed machines workspace`](../machines-workspace/README.md) for the saved multi-pane
  layouts.
- [`ed system`](../system/README.md) for the same metrics report taken on this Mac.
- [Conventions and contracts](../conventions.md) for the exit code table and the
  `--json` guarantee in full.
- [The `ed` command line](../README.md) for the rest of the reference.
