# `ed <machine> <command...>`

Names a machine as the first word of the line and runs the rest there. It is
pure argument rewriting: `ed` reshapes `argv` before the parser ever sees it,
then the ordinary `ed machines exec` runs.

```
ed <machine> <command...>
ed <machine>
```

The rewrite happens in this order, and stops at the first rule that applies:

| When the first word | The line becomes |
| --- | --- |
| is missing, or starts with `-` | unchanged |
| is `machines` | reordered by the machine-first rule below |
| is a top level command name or alias, or `help`, or `__complete` | unchanged |
| does not match a configured machine name or ssh alias | unchanged |
| matches a machine, and something after it does not start with `-` | `machines exec <machine> -- <rest>` |
| matches a machine, and the rest is empty or all flags | `machines show <machine> <rest>` |

The match against your machines is by whole name or whole ssh alias,
case-insensitively. It is deliberately stricter than the resolver `ed machines
exec` then uses: a prefix or a UUID is not enough to trigger the shorthand, so
`ed tu uptime` is not rewritten and fails as an unknown command with exit 2,
while `ed tuf uptime` and `ed 'asus tuf 7' uptime` both run.

The reserved list that wins over a machine name is every top level command and
alias: `guide`, `schema`, `version`, `completions`, `install`, `uninstall`,
`config`, `app`, `extensions`, `permissions`, `usage`, `system`, `music`,
`nowplaying`, `np`, `calendar`, `tools`, `apps`, `download`, `downloads`, `dl`,
`clipboard`, `color`, `colour`, `shelf`, `cleaner` and `machines`, plus `help`
and `__complete`. A machine called `usage` is unreachable by the shorthand and
has to be named explicitly, as `ed machines exec usage -- ...` or
`ed machines show usage`.

Because the rewrite inserts `--` after the machine name, every flag after it
belongs to the machine, never to `ed`. That is what lets `ed tuf ls -la` and
`ed tuf docker compose up -d` work without ceremony, and it is why `--tty` has
no shorthand: write `ed machines exec --tty tuf top`.

`ed tuf docker ps` runs the machine's own `docker` binary and prints its raw
output. The parsed, `--json` version is `ed machines docker ps tuf`, which is a
different command. Both are correct; the shorthand is always the raw one.

## The machine-first spelling under `ed machines`

A word straight after `machines` that is not one of the group's subcommands is
treated as the machine and moved to wherever the subcommand wants it. `ed` walks
as far down the subcommand tree as the words allow, then inserts the machine
after the last subcommand it consumed:

```
ed machines tuf uptime            ed machines exec tuf -- uptime
ed machines tuf docker ps         ed machines docker ps tuf
ed machines tuf files ls /etc     ed machines files ls tuf /etc
ed machines tuf run ls -la        ed machines run tuf -- ls -la
ed machines tuf                   ed machines show tuf
```

Unlike the top level shorthand this does not check your machine list at all, so
a typo is still moved into the machine slot and the error names it rather than
complaining about an unknown subcommand:

```
$ ed machines nosuchbox uptime
error: no machine named nosuchbox
hint: known machines: Asus TUF 7; machines subcommands: add, broadcast, connect, disconnect, docker, edit, exec, files, forward, forwards, kill, list, ls, metrics, power, remove, rm, run, services, show, snippet, snippets, workspace, workspaces
```

A subcommand name always wins. The names that cannot be used as a machine here
are `ls`, `list`, `show`, `add`, `edit`, `rm`, `remove`, `forwards`, `forward`,
`snippets`, `snippet`, `power`, `workspace`, `workspaces`, `broadcast`, `kill`,
`metrics`, `exec`, `run`, `files`, `docker`, `services`, `connect` and
`disconnect`. A machine literally called `docker` needs
`ed machines show docker`.

## Examples

```
ed tuf uptime
ed tuf systemctl status nginx
ed tuf 'ls -la /srv | head'
ed machines tuf docker compose ls
```

## Behaviour notes

A bare machine name is a lookup, not a shell:

```
$ ed tuf
Asus TUF 7
  target   tuf · pulkit@192.168.1.12
  auth     SSH agent
  system   Linux 7.0.0-28-generic x86_64
  uptime   22:25:13 up  9:17,  5 users,  load average: 0.03, 0.08, 0.21
  session  pulkit on seat0 since 2026-08-08 13:08 (login screen)
  session  pulkit on tty2 since 2026-08-08 13:08 (tty2)
```

Flags alone count as nothing runnable, so `ed tuf --json` is
`ed machines show tuf --json` rather than an attempt to run `--json` on the
machine.

## Where to go next

- [Running commands on a machine](./README.md), the rest of this group
- [All `ed` commands](../README.md)
