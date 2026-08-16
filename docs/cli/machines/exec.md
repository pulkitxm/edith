# `ed machines exec`

Runs a command on a machine, passing stdin, stdout, stderr and the remote exit
code straight through. `run` is an accepted alias.

```
ed machines exec [--tty] <machine> [--] <command...>
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | string, required | none | Machine name, ssh alias, id or unambiguous prefix. |
| `<command...>` | words, required in practice | empty | The command to run. Everything after the machine name is captured verbatim, flags included. A leading `--` is stripped. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--tty`, `-t` | flag | off | Run it on a terminal, so `vim`, `top`, a `sudo` password prompt and `docker exec -it` work. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

There is no `--json` here. The output is the remote command's output and nothing
else.

## Examples

```
ed machines exec studio -- uptime
ed studio uptime
ed machines exec --tty studio -- top
ed studio 'ls -la /srv | head'
```

## Behaviour notes

This is the one command on the page whose exit code is not Edith's. The remote
process's status becomes yours, so a `grep` that matched nothing exits 1 and a
missing command exits 127, neither of which means `ed` failed. The `--tty` path
returns ssh's own status the same way.

Arguments are quoted individually before they are sent, so an argument
containing spaces survives. Shell metacharacters do not: to use a pipe, a
redirection or a glob on the machine, quote the whole line as in the last
example. A single-word command is sent verbatim, unquoted.

`cd` is special when it is the whole command: `ed studio cd Desktop` records a
working directory for that terminal rather than running anything, and later
commands are prefixed with it. `cd -` goes back, `cd` with no argument goes
home, and a path that does not exist exits 1 with the machine's own error and
leaves the current directory alone. The full model, including how the directory
is scoped to one terminal and how remote completion follows it, is on
[running commands on a machine](../machines-remote/README.md).

Naming no command at all exits 1:

```
$ ed machines exec studio
error: name a command to run, for example `ed studio uptime`
```

An unknown machine exits 3, an unreachable one exits 4.

### Subcommands documented elsewhere

Between `exec` and `connect`, `ed machines` declares seven more subcommands.
They are part of this group and resolve machines the same way, but they are
documented elsewhere:

```
ed machines files ...        browsing, transfers, the Finder operations and undo
ed machines docker ...       containers, images, volumes, networks, compose
ed machines power ...        status, reboot, shutdown, wake-on-LAN
ed machines kill ...         end a process by pid
ed machines broadcast ...    one command on every configured machine
ed machines workspace ...    the saved multi-pane layouts
```

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
