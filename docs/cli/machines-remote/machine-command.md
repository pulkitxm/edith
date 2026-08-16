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
while `ed studio uptime` and `ed 'studio mac' uptime` both run.

The reserved list that wins over a machine name is every top level command and
alias: `guide`, `schema`, `version`, `completions`, `install`, `uninstall`,
`config`, `app`, `extensions`, `permissions`, `usage`, `system`, `music`,
`nowplaying`, `np`, `calendar`, `tools`, `apps`, `download`, `downloads`, `dl`,
`clipboard`, `color`, `colour`, `shelf`, `cleaner` and `machines`, plus `help`
and `__complete`. A machine called `usage` is unreachable by the shorthand and
has to be named explicitly, as `ed machines exec usage -- ...` or
`ed machines show usage`.

Because the rewrite inserts `--` after the machine name, every flag after it
belongs to the machine, never to `ed`. That is what lets `ed studio ls -la` and
`ed studio docker compose up -d` work without ceremony, and it is why `--tty` has
no shorthand: write `ed machines exec --tty studio top`.

`ed studio docker ps` runs the machine's own `docker` binary and prints its raw
output. The parsed, `--json` version is `ed machines docker ps studio`, which is a
different command. Both are correct; the shorthand is always the raw one.

## The machine-first spelling under `ed machines`

A word straight after `machines` that is not one of the group's subcommands is
treated as the machine and moved to wherever the subcommand wants it. `ed` walks
as far down the subcommand tree as the words allow, then inserts the machine
after the last subcommand it consumed:

```
ed machines studio uptime            ed machines exec studio -- uptime
ed machines studio docker ps         ed machines docker ps studio
ed machines studio files ls /etc     ed machines files ls studio /etc
ed machines studio run ls -la        ed machines run studio -- ls -la
ed machines studio                   ed machines show studio
```

Unlike the top level shorthand this does not check your machine list at all, so
a typo is still moved into the machine slot and the error names it rather than
complaining about an unknown subcommand:

```
$ ed machines nosuchbox uptime
error: no machine named nosuchbox
hint: known machines: Studio Mac; machines subcommands: add, broadcast, connect, disconnect, docker, edit, exec, files, forward, forwards, kill, list, ls, metrics, power, remove, rm, run, services, show, snippet, snippets, workspace, workspaces
```

A subcommand name always wins. The names that cannot be used as a machine here
are `ls`, `list`, `show`, `add`, `edit`, `rm`, `remove`, `forwards`, `forward`,
`snippets`, `snippet`, `power`, `workspace`, `workspaces`, `broadcast`, `kill`,
`metrics`, `exec`, `run`, `files`, `docker`, `services`, `connect` and
`disconnect`. A machine literally called `docker` needs
`ed machines show docker`.

## Examples

```
ed studio uptime
ed studio launchctl print system
ed studio 'ls -la /srv | head'
ed machines studio docker compose ls
```

## Behaviour notes

A bare machine name is a lookup, not a shell:

```
$ ed studio
Studio Mac
  target   studio · pulkit@192.168.1.12
  auth     SSH agent
  system   Darwin 25.6.0 arm64
  uptime   22:25:13 up  9:17,  5 users,  load average: 0.03, 0.08, 0.21
  session  pulkit on console since 2026-08-08 13:08
  session  pulkit on ttys001 since 2026-08-08 13:09
```

Flags alone count as nothing runnable, so `ed studio --json` is
`ed machines show studio --json` rather than an attempt to run `--json` on the
machine.

## Where to go next

- [Running commands on a machine](./README.md), the rest of this group
- [All `ed` commands](../README.md)
