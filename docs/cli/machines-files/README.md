# `ed machines files`

`ed machines files` is a file manager for a machine you have already told Edith
about. It lists directories, moves files in both directions, and runs the same
copy, move, rename, trash, search and duplicate operations the app's Files pane
runs. Reach for it when you want to look at or rearrange something on another
box without opening a shell there, and when you want the result in JSON.

Everything here except `undo` and `open` is plain shell sent over the SSH
connection Edith already holds, so nothing is installed on the machine and Edith
does not have to be running. Those two are the exceptions, because the history
one reverses lives in the running app, and the window the other raises belongs
to Edith Files.

## At a glance

| Command | What it does |
| --- | --- |
| `ed machines files ls` | List a remote directory. The default subcommand. Aliased `list`. |
| `ed machines files get` | Download one file from the machine. |
| `ed machines files put` | Upload one file to the machine. |
| `ed machines files cp` | Copy paths into a directory there. |
| `ed machines files mv` | Move paths into a directory there. |
| `ed machines files rename` | Rename one path in place. |
| `ed machines files mkdir` | Make a directory, parents included. |
| `ed machines files rm` | Move paths to the machine's trash, or delete them outright. |
| `ed machines files search` | Find files by name under a directory. |
| `ed machines files info` | Measure a path with `du`, directories included. |
| `ed machines files duplicate` | Copy a file beside itself, the way the window does. |
| `ed machines files undo` | Undo the last move or rename an open Files pane made. |
| `ed machines files open` | Open a Files window on a directory, by default the one this terminal is in. Starts Edith Files when it is closed. |

## How these reach the machine

Every verb but `undo` resolves the machine, opens or reuses the shared
ControlMaster socket, and sends one command line. A machine resolves by display
name, SSH alias, id, or any unambiguous prefix, case-insensitively; an unknown
or ambiguous name exits 3 before anything is sent. A machine that cannot be
reached exits 4 with what `ssh` said:

```
$ ed machines files ls tuf
error: could not reach Asus TUF 7: Connection refused
hint: check the machine is awake and reachable, then retry
```

Two spellings put the machine in different places, and both work:

```
ed machines files ls tuf /var/log
ed machines tuf files ls /var/log
```

`ed tuf files ls` is not one of them. A machine name in the first position is
shorthand for `ed machines exec`, so that line runs `files ls` as a command on
the machine and the machine says it does not exist.

Paths are quoted individually before they are sent, so spaces and shell
metacharacters survive intact. The other side of that is that the machine never
expands a glob for you: `ed machines files cp tuf '/var/log/*.log' /tmp` looks
for a file literally named `*.log`. Quote the whole line through
`ed tuf 'cp /var/log/*.log /tmp'` when you want the remote shell to expand it.
The exception is `search`, whose text is handed to `find -iname`, which does its
own matching.

A relative path is resolved by the machine against the SSH login directory,
normally the home directory. The working directory `ed tuf cd` remembers belongs
to `ed machines exec`, and `open` is the one verb here that reads it, so a
Files window opens where the shell in that terminal left off.

## Commands

## Commands

- [`ed machines files ls`](./ls.md)
- [`ed machines files get`](./get.md)
- [`ed machines files put`](./put.md)
- [`ed machines files cp`](./cp.md)
- [`ed machines files mv`](./mv.md)
- [`ed machines files rename`](./rename.md)
- [`ed machines files mkdir`](./mkdir.md)
- [`ed machines files rm`](./rm.md)
- [`ed machines files search`](./search.md)
- [`ed machines files info`](./info.md)
- [`ed machines files duplicate`](./duplicate.md)
- [`ed machines files undo`](./undo.md)
- [`ed machines files open`](./open.md)

## Exit codes

| Code | What produced it |
| --- | --- |
| 0 | The command did what it says. Also the `--delete` dry run of `rm`, a `search` with no matches, `info` on a path that does not exist, `mkdir` on a directory that is already there, and `ls` of an empty directory. |
| 1 | The machine ran the command and it failed: a `cp`, `mv`, `mkdir` or `rm` the account is not allowed to make, a `rename` onto a name already taken, a `duplicate` that could not be written, a `get` or `put` that failed its checks, an `ls` that could read nothing. Also the local refusals: fewer than two paths for `cp` or `mv`, no path for `rm`, a slash in a `rename` name. |
| 2 | `--limit` of zero or less on `search`. Also any parse failure: an unknown flag, a missing positional, a `--limit` that is not a number. |
| 3 | No machine matches the name, more than one does, or no machines are configured at all. Also `put` when there is no local file at the path given. |
| 4 | The machine could not be reached, or the SSH transport failed part way through a command. Also all three ways `undo` gives up: Edith's main window closed, no pane with anything to undo, or no reply in 20 seconds. `open` uses it when Edith Files cannot be found or will not start, and when a running one never answers. |

## Notes and gotchas

Nothing in this group needs Edith running except `undo`, which wants the main
window rather than the menu bar helper and refuses when it is closed, because
the history it reverses died with it. `open` needs no Edith at all: it starts
Edith Files, which is its own app. The rest go straight down the
ControlMaster socket the app and `ed` share, so they work with Edith closed and
they reuse an open connection when it is there.

Nothing here tells a running Edith what changed. A Files pane showing the
directory you just rearranged from the command line keeps showing the old
listing until it is refreshed with Command-R. The traffic only goes the other
way, through `undo`.

The timeouts are fixed and worth knowing when a machine is slow: 15 seconds for
the `$HOME` probe, 20 for the `test -d` probe `put` makes, 30 for the `stat`
calls around a transfer, the one `get` makes to size the remote file and the one
`put` makes to check what landed, 45 for a directory listing, 120 for `search`
and `info`, 300 for `cp`, `mv`, `rename`, `mkdir`, `rm` and `duplicate`, and 20
for the `undo` reply. The transfer itself has no timeout at all, because a slow
file is not a broken one.

A failed command and a broken connection are different exit codes on purpose. A
command the machine ran and rejected exits 1 with the machine's own message
appended; a connection that could not be opened or that dropped mid-command
exits 4. Gate a script on 4 for "try again later" and on 1 for "this will not
work".

`--json` never changes what happens on the machine, only what is printed. Every
verb here prints exactly one document per invocation, with object keys sorted,
diagnostics on stderr only, and no streaming mode. `search` is the one whose
document is an array rather than an object, and `rm`'s dry run is the one whose
document has a different shape from its success. The transfer meter on `get` and
`put` is the one thing `--json` switches off rather than reshapes, because it is
stderr furniture rather than anything printed on stdout.

`--yes` exists on `rm` only, and only `--delete` consults it. Passing `--yes`
without `--delete` changes nothing: trashing never asks, because the machine's
trash can give the file back.

The remote trash is the freedesktop directory under the login home, whatever the
machine's desktop environment would normally use. On a machine with no desktop
at all the files still land in `~/.local/share/Trash/files`, which is a fine
place to find them but not somewhere anything will empty for you.

Shell completion knows this group only as far as the names it already holds:
after `ed machines files` it offers the verbs, and in the machine slot it offers
the configured machines. Remote paths are not completed at all, so Tab where a
path goes offers nothing of its own and never dials the machine. The completion
that does ask a machine, for command names and paths, belongs to the
`ed <machine> ...` shorthand, and even there only when a ControlMaster socket
for that machine is already open.

## Where to go next

- [`ed machines`](../machines/README.md) is where machines are added, named and
  connected, and where the name every command here takes comes from.
- [Running commands on a machine](../machines-remote/README.md) covers
  `ed machines exec` and the `ed <machine> ...` shorthand, which is the escape
  hatch for anything this group does not do.
- [`ed machines workspace`](../machines-workspace/README.md) explains the panes, one of
  which is the Files pane whose history `undo` reverses.
- [Conventions and contracts](../conventions.md) has the full exit code and JSON
  contract these pages assume.
- [All command groups](../README.md)
