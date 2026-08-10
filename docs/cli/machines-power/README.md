# `ed machines power`

`ed machines power` is the run state of another machine: whether it is up, and
the three things you can tell it to do about that, which are restart, shut down
and wake. This page also covers the neighbouring verbs that act on what is
running there rather than on the machine itself: `ed machines services` for
systemd units, `ed machines kill` for a single process, and
`ed machines broadcast` for one line on every machine at once.

Everything here is the Tools tab of a machine window as a command, plus the
terminal's broadcast bar. Nothing here needs the Edith app to be running:
`status` reads the machine file on disk, `wake` opens a UDP socket, and the rest
go out over `/usr/bin/ssh` on the ControlMaster socket Edith and `ed` share.

Most of this page is disruptive. Read the next table before you type anything.

| Command | Disruptive? |
| --- | --- |
| `ed machines power status` | No. Reads the machine file and pokes the local control socket. Never contacts the machine. |
| `ed machines power reboot` | Yes, and it takes the machine down. Refuses to act without `--yes`. |
| `ed machines power shutdown` | Yes, and the machine will not come back without `wake` or a physical power button. Refuses to act without `--yes`. |
| `ed machines power wake` | Mildly. It puts one broadcast packet on the local network and nothing else. |
| `ed machines services ls` | No. Reads `systemctl list-units`. |
| `ed machines services start` | Yes, it changes a unit's state. No confirmation flag. |
| `ed machines services stop` | Yes, it changes a unit's state. No confirmation flag. |
| `ed machines services restart` | Yes, it changes a unit's state. No confirmation flag. |
| `ed machines kill` | Yes, it signals a live process. No confirmation flag. |
| `ed machines broadcast` | As disruptive as the line you give it, multiplied by every machine you own. No confirmation flag. |

Only `reboot` and `shutdown` have a `--yes` gate. `services stop`, `kill` and
`broadcast` act the moment you press return.

## At a glance

| Command | What it does |
| --- | --- |
| `ed machines power status` | Reports whether a shared connection is open, the stored MAC address, and which power verbs are possible right now. Runs when you type `ed machines power <machine>` with no verb. |
| `ed machines power reboot` | Restarts the machine through systemd. Does nothing without `--yes`. Aliased as `restart`. |
| `ed machines power shutdown` | Powers the machine off through systemd. Does nothing without `--yes`. Aliased as `poweroff`. |
| `ed machines power wake` | Sends a wake-on-LAN magic packet to the machine's stored MAC address. The one verb that works while the machine is off. |
| `ed machines services ls` | Lists systemd service units, with `--failed` to narrow to broken ones. Runs when you type `ed machines services <machine>` with no verb. |
| `ed machines services start` | Starts one unit. |
| `ed machines services stop` | Stops one unit. |
| `ed machines services restart` | Restarts one unit. |
| `ed machines kill` | Sends a signal to one process id, `TERM` unless you name another. |
| `ed machines broadcast` | Runs one command on every configured machine, labels each machine's output, and exits 1 if any of them failed. |

## Two ways to name the machine

Every command on this page except `broadcast` takes the machine as a positional
argument, and the machine can come first instead. The first line of each pair
below puts the verb first and the machine last, the second puts the machine
first.

```
ed machines power reboot tuf --yes
ed machines tuf power reboot --yes
ed machines services restart tuf nginx.service
ed machines tuf services restart nginx.service
```

Both forms parse to the same thing. What does not work is the bare shorthand:
`ed tuf power reboot` is `ed machines exec tuf -- power reboot`, so it looks for
a program called `power` on the far side and fails there. The shorthand always
means "run this on the machine", so reach for `ed machines tuf ...` when you
want Edith's own verb.

A machine resolves by display name, SSH config alias, id, or any unambiguous
case-insensitive prefix. An unknown or ambiguous name exits 3 with the
candidates in the hint, and never guesses.

## Commands

## Commands

- [`ed machines power status`](./power-status.md)
- [`ed machines power reboot`](./power-reboot.md)
- [`ed machines power shutdown`](./power-shutdown.md)
- [`ed machines power wake`](./power-wake.md)
- [`ed machines services ls`](./services-ls.md)
- [`ed machines services start`](./services-start.md)
- [`ed machines services stop`](./services-stop.md)
- [`ed machines services restart`](./services-restart.md)
- [`ed machines kill`](./kill.md)
- [`ed machines broadcast`](./broadcast.md)

## Exit codes

| Code | When |
| --- | --- |
| 0 | The command did what it says. Also the dry run of `reboot` and `shutdown` without `--yes`, `services ls` on a machine with no systemd, and `--help` on any of these. |
| 1 | The machine refused a reboot or shutdown; a unit verb failed or came back with a privilege message; `kill` was rejected by the far side or given a pid of zero or less; the wake packet could not be built or sent; `broadcast` had at least one machine return non-zero; `broadcast` was given an empty command. |
| 2 | The command line was wrong: an unknown flag, a missing machine, unit or command, or a pid that is not an integer. |
| 3 | The machine name is unknown or an ambiguous prefix; `--signal` named something that is not one of the seven; `broadcast` found no machines configured, or `--only` named a machine that does not exist. |
| 4 | The machine could not be reached, which covers every verb that opens a connection; or `wake` was asked for a machine with no stored MAC address. |

`broadcast` never exits 4 for an unreachable machine, because reaching some and
not others is the case it exists to handle. That failure becomes a `-1` row and
folds into the overall exit 1.

None of these codes ever comes from Edith not running. Nothing on this page
talks to the app.

## Notes and gotchas

- Nothing here needs the Edith app or the menu bar helper. `status` reads the
  machine file under `~/Library/Application Support/Edith` and the control
  socket; `wake` opens a UDP socket; everything else is `/usr/bin/ssh`. No macOS
  permission is involved either, so exit 4 on this page always means the machine
  is unreachable or unknown to wake-on-LAN, never that Edith is closed.
- The privilege fallback runs in different orders in the two families. `reboot`
  and `shutdown` try `sudo -n systemctl ...` first and fall back to plain
  `systemctl`. The unit verbs try plain `systemctl ...` first and fall back to
  `sudo -n`. Both fold stderr into stdout with `2>&1`, so both attempts' output
  arrives in one string.
- That has a sharp edge on the unit verbs. Because the first attempt's output is
  still in the buffer, a `start` that only succeeded through the sudo fallback
  can carry the first attempt's *Interactive authentication required* text, and
  the presence of that phrase alone is enough for `ed` to call it a failure. The
  unit changes state on the machine and `ed` exits 1 saying it could not. If you
  see that, check with `ed machines services ls <machine>` before retrying.
- A stored sudo password removes both of those. Every privileged verb becomes a
  single `sudo -S -p '' systemctl ...` with the password on standard input, so
  there is no second attempt to leave stale text in the buffer and no order to
  get wrong. A password the machine rejects is reported as rejected, with a hint
  naming the flag that replaces it, rather than as a missing privilege.
- The phrases that count as a privilege problem are `password is required`,
  `interactive authentication required`, `access denied`, `not authorized` and
  `permission denied`, matched case-insensitively anywhere in the output. A unit
  whose own log line happens to contain one of them is judged the same way.
- `power status` answers about the control socket, not about the machine.
  `connected: false` on a machine that is up simply means no shared connection
  is open yet, and the next command will open one.
- A reboot that takes the connection down with it is meant to be treated as
  success, and the code has a branch for exactly that, keyed on ssh reporting
  status 255 or a closed connection. That branch only fires for an error thrown
  by the SSH layer, and the layer returns the exit status instead of throwing
  it, so in practice an ssh that exits 255 because the host vanished is reported
  as a refusal and exits 1. The normal case is unaffected, because
  `systemctl reboot` returns 0 before the host goes down.
- `--yes` exists on `reboot` and `shutdown` only. `services stop`, `kill` and
  `broadcast` are all capable of taking a machine off the network and none of
  them asks first.
- Object keys in every `--json` document on this page are sorted
  lexicographically, and each invocation prints exactly one document, so output
  diffs cleanly and `jq` never sees a stream. `--json` is declared per command
  and is long-form only; there is no `-j`.
- A failing command prints nothing on stdout, with one exception:
  `ed machines broadcast` prints its blocks or its array and then exits 1 when a
  machine failed.
- `ed machines power` with no verb and no machine exits 2, because the default
  subcommand still wants a machine. `ed machines power <machine>` is
  `ed machines power status <machine>`, and `ed machines services <machine>` is
  `ed machines services ls <machine>`.
- Aliases: `power reboot` is also `power restart`, `power shutdown` is also
  `power poweroff`, and `services ls` is also `services list`. The `action`
  field in JSON always carries the canonical name, `reboot` or `shutdown`.
- Shell completion knows this whole subtree, including machine names in the
  machine slot. It does not complete unit names or pids, because those would
  need a round trip to the machine.

## Where to go next

- [`ed machines`](../machines/README.md) for the machine directory itself, including
  `ed machines edit <machine> --mac <address>` to teach `wake` an address, and
  `ed machines metrics` for the process list `kill` needs.
- [Running commands on a machine](../machines-remote/README.md) for the raw form, which
  is where `systemctl enable`, `journalctl` and anything else not covered here
  belongs.
- [`ed machines docker`](../machines-docker/README.md) for the container equivalents of
  start, stop, restart and rm.
- [`ed machines files`](../machines-files/README.md) for moving things onto and off a
  machine.
- [Conventions and contracts](../conventions.md) for the full exit code table and
  the `--json` guarantee.
- [The `ed` command line](../README.md) for the rest of the reference.
