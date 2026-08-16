# `ed machines broadcast`

Runs one command on every configured machine, one after another, and labels each
machine's output.

```
ed machines broadcast [--only <a,b>] [--json] [--] <command...>
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<command...>` | everything remaining | required | The command to run everywhere. Captured verbatim to the end of the line, joined with single spaces. A leading `--` is dropped. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--only` | comma-separated machine names | unset, meaning every configured machine | Restrict to these machines. Each entry is trimmed of surrounding spaces and resolved like any machine name, so aliases and prefixes work. |
| `--json` | flag | off | Emit JSON on stdout instead of the labelled blocks. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

Flags belong before the command, because everything from the first non-flag word
onwards is the command. Use `--` to make that boundary explicit:

```
$ ed machines broadcast -- uptime
== Studio Mac ==
 22:14:03 up 6 days,  3:41,  2 users,  load average: 0.42, 0.51, 0.48
== Home Box ==
 22:14:05 up 19:02,  1 user,  load average: 0.08, 0.03, 0.01
```

A machine whose command failed still shows its output, and the exit note goes to
stderr:

```
$ ed machines broadcast --only studio,box -- docker ps -q
== Studio Mac ==
b556d7fef23e
f8968a8b81e5
== Home Box ==
bash: line 1: docker: command not found
Home Box exited 127
```

## `--json` shape

A top-level array, one object per machine, in the order they were tried:

```json
[
  {
    "machine": "Studio Mac",
    "output": "b556d7fef23e\nf8968a8b81e5",
    "status": 0
  },
  {
    "machine": "Home Box",
    "output": "bash: line 1: docker: command not found",
    "status": 127
  },
  {
    "machine": "Pi 4",
    "output": "The operation couldn’t be completed. (EdithCLI.CLIFailure error 1.)",
    "status": -1
  }
]
```

`status` is the remote exit code, or `-1` when the machine could not be reached
or the connection broke mid-command. `output` is stdout and stderr concatenated
and trimmed, and for a `-1` row it is Foundation's generic description of the
error rather than the reachability message you would get from
`ed machines connect`, so treat a `-1` as "could not run", not as text worth
parsing.

The whole array is emitted at the end, in one document. In the human form the
blocks stream as each machine finishes.

## Examples

```
ed machines broadcast -- uptime
ed machines broadcast --only studio,box -- df -h /
ed machines broadcast --json -- 'launchctl print system' | jq -r '.[] | "\(.machine) \(.output)"'
ed machines broadcast -- 'apt list --upgradable 2>/dev/null | wc -l'
```

## Behaviour notes

This is the terminal's broadcast bar as a command, aimed at every configured
machine rather than at the open panes. Machines are contacted one at a time, not
in parallel, each with its own 120 second timeout, so a run across five machines
can take ten minutes in the worst case. Each one opens or reuses the shared
ControlMaster socket, so a sleeping host is dialled rather than skipped.

A machine that cannot be reached is reported and the rest still run. That is the
point of the verb: one unreachable host does not cost you the other answers.

The exit code is 1 if any machine returned a non-zero status, including the `-1`
rows. It is the one command in this group that writes real output to stdout and
still exits non-zero, so gate on the exit code first and read the array second.

Arguments are joined with a single space and sent as one line to the remote
shell, which means shell metacharacters are the machine's to interpret, not
yours. Quote the whole line when you want a pipe, a redirect or a glob to run
over there, as in the last example above.

Failure to give a command at all exits 2 from the parser. A command that is only
whitespace, or a bare `--`, exits 1 with `give a command to run`. With no
machines configured it exits 3:

```
$ ed machines broadcast -- uptime
error: no machines are configured
hint: add one with `ed machines add`
```

`--only` resolves every name before any command runs, so one bad name exits 3
and nothing is executed anywhere. Names may repeat, and the machine then runs
the command twice.

## Where to go next

- [`ed machines power`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
