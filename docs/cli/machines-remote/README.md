# Running commands on a machine

`ed machines exec` runs one command on a configured machine over the SSH
connection Edith already holds, hands you the machine's stdout and stderr on
your own stdout and stderr, and exits with the status the remote command
exited with. `ed <machine> <command...>` is the same thing with the ceremony
removed: name a machine as the first word and the rest of the line runs there.

This is the escape hatch under every other `ed machines` verb. `docker`,
`files`, `power` and `services` exist because a parsed, `--json` answer is
worth having for the things you script; everything else on the machine is
reachable by typing it. Nothing here needs the Edith app to be running, because
the transport is `/usr/bin/ssh` and a ControlMaster socket on disk rather than a
request to the app.

## At a glance

| Command | What it does |
| --- | --- |
| `ed machines exec <machine> <command...>` | Runs the command over the shared connection with no pty, streaming both output channels and propagating the remote exit code. |
| `ed machines exec --tty <machine> <command...>` | The same, on a real terminal, which is what `vim`, `top`, a `sudo` password prompt and `docker exec -it` need. |
| `ed machines run <machine> <command...>` | Alias of `ed machines exec`. |
| `ed <machine> <command...>` | Shorthand that rewrites to `ed machines exec <machine> -- <command...>`. |
| `ed <machine>` | A bare machine name with nothing runnable after it is `ed machines show <machine>`. |
| `ed <machine> cd [<directory>]` | Sets the working directory the later commands on that machine run in, per terminal. |
| `ed machines <machine> <command...>` | The machine-first spelling: a word after `machines` that is not a subcommand is moved to wherever that subcommand wants it. |
| `ed __complete` | Hidden. Emits completion candidates, and hands over to the machine for anything after a machine name. |

## Commands

## Commands

- [`ed machines exec`](./exec.md)
- [`ed <machine> <command...>`](./machine-command.md)
- [`ed <machine> cd [<directory>]`](./machine-cd-directory.md)
- [`ed __complete`](./complete.md)

## Exit codes

| Code | When |
| --- | --- |
| 0 | The remote command exited 0, or a `cd` landed. `--help` also exits 0, and so does a completion probe with nothing to offer. |
| 1 | No command word was given; a `cd` the machine refused; `cd -` with no previous directory recorded for this terminal; ssh could not be started at all. Also produced when the remote command itself exits 1. |
| 2 | The command line was wrong: an unknown option before the machine name, such as `--json`, or a missing machine argument. Also produced when the remote command itself exits 2. |
| 3 | The machine did not resolve: nothing is configured, the name is unknown, or a prefix matched more than one machine. The hint lists the candidates and the `machines` subcommands. |
| 4 | The connection could not be opened. The message is `could not reach <machine>: <reason>`, with the reason translated from ssh's own text: authentication failed, connection refused, timed out, could not resolve the host name, or the host key changed. |
| anything | The remote command's own status, passed through unchanged, so `127` for a command the machine does not have, `130` for one you interrupted, and anything else a program chooses to return. |

Codes 1, 2, 3 and 4 are also values a remote program can return, and `ed` cannot
tell you which side produced one. When a script needs to know, look at stderr:
`ed`'s own failures always start with `error:` and never touch stdout.

## Notes and gotchas

- The exit code passthrough is the single documented hole in the CLI's 0 to 4
  contract. `ed machines exec`, the shorthand, `ed machines docker logs` and
  `ed machines docker compose logs` are the only commands that do it.
- `--tty` is the counterpart of the app's Machine terminal pane, and of the
  Docker window's shell button, which is `ed machines exec --tty <machine>
  'docker exec -it <container> sh'`.
- The plain path gives the remote process no terminal at all. Anything that
  checks `isatty` will disable colour and progress bars, which is usually what
  you want from a script and never what you want from `top`.
- A single leading `--` is stripped, once. `ed machines exec tuf -- -- ls`
  sends `-- ls`.
- The shorthand and the machine-first spelling both leave a word alone when it
  starts with `-`, so `ed --help` and `ed machines --help` are never mistaken
  for machine names.
- `ed <machine>` with only flags after it is `ed machines show`, which opens a
  connection and runs `uname`, `uptime` and `who` on the machine. It is not a
  free lookup.
- The remembered working directory is per terminal, not per shell. Two panes in
  the same terminal emulator have different `ttys` names and so different
  directories; a subshell inside one pane shares its parent's.
- Everything a pipe touches uses the `shared` session slot, so
  `ed tuf cd /tmp` typed at a prompt does not change where a cron job's
  `ed tuf make` runs, and two concurrent scripts do share one slot.
- The ControlMaster socket lives at
  `~/Library/Application Support/Edith/machines/sockets/<hash>.sk`, keyed by the
  same ten characters of the machine id that name the working directory folder.
  `ed machines disconnect <machine>` closes it, which also silences remote
  completion until something opens it again.
- Host keys are pinned in Edith's own `known_hosts` beside that socket, with
  your `~/.ssh/known_hosts` consulted as well and `StrictHostKeyChecking` set to
  `accept-new`. Do not shell out to `ssh` directly for a configured machine; you
  lose the shared connection and the pinning.
- Neither the Edith app nor the menu bar helper has to be running for anything
  on this page, and no macOS permission is involved.
- `ed machines exec` takes no `--json`, and neither does the shorthand. If you
  want structured output, run something on the machine that produces it and pipe
  the result into `jq` yourself.
- `ed machines broadcast` is the many-machine version of the same idea: one line
  on every configured machine, output labelled per machine, and exit 1 if any of
  them failed rather than the remote status. It does not honour the remembered
  working directory.

## Where to go next

- [`ed machines`](../machines/README.md) for the machine list itself, connecting and
  disconnecting, and the saved forwards and snippets the terminal pane uses.
- [`ed machines docker`](../machines-docker/README.md) for the parsed, `--json` half of
  what `ed <machine> docker ...` reaches raw.
- [`ed machines files`](../machines-files/README.md) for moving files, which is also how
  you get data onto a machine given that stdin does not travel.
- [`ed machines power`](../machines-power/README.md) for reboot, wake, systemd units and
  killing a process by pid.
- [Getting started](../getting-started/README.md) for installing the completion scripts
  that call `ed __complete`.
- [Conventions and contracts](../conventions.md) for the exit code table this
  page is the exception to.
- [The `ed` command line](../README.md) for the rest of the reference.
