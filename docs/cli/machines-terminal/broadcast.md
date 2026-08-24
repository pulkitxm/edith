# `ed machines terminal broadcast`

Sends one line to every terminal tab currently open for one machine in the
Edith main app. It is the command-line equivalent of the terminal view's
Broadcast field.

```
ed machines terminal broadcast <machine> [--] <command...> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, SSH alias, UUID or unambiguous prefix | required | Which machine's open terminal tabs receive the line. |
| `<command...>` | words, required | none | The line to write, followed by one newline. Use `--` before option-like command words. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit one result object on stdout. |
| `--help`, `-h` | flag | off | Print this command's help and exit 0. |

```
$ ed machines terminal broadcast tuf -- uptime
sent to 2 open tabs on Asus TUF 7: uptime
```

## `--json` shape

```json
{
  "command": "uptime",
  "machine": "Asus TUF 7",
  "machineID": "4303DCF1-52D8-4075-AE9B-C2FD86D3821A",
  "tabs": 2
}
```

## Behaviour notes

The line is trimmed at both ends, then one newline is appended. Every open tab
registered for the resolved machine UUID receives the same bytes on the main
actor. Tabs for other machines are untouched. The reported `tabs` count is the
number of terminal processes targeted across every open terminal view for that
machine.

The caller's shell splits arguments before `ed` sees them. When the line itself
needs quotes, redirection, pipes or other shell syntax, quote the whole line so
those characters reach the open terminals intact.

An empty line exits 2 before contacting the app. An unknown machine exits 3. A
known machine with no open terminal tabs also exits 3 and tells you to open one.
A closed or unresponsive main app exits 4. A malformed or unrelated app reply
exits 1. No SSH connection is opened by this command.

This is not [`ed machines broadcast`](../machines-power/README.md). That command
runs one new SSH command on every configured machine, or on the `--only` subset,
and collects each remote exit status. This command writes into existing terminal
tabs for exactly one machine.

## Examples

```
ed machines terminal broadcast tuf -- uptime
ed machines terminal broadcast tuf -- "printf '%s\n' ready"
ed machines terminal broadcast tuf uptime --json
```

## Where to go next

- [`ed machines terminal`](./README.md), the rest of this group
- [`ed machines`](../machines/README.md), machine setup and SSH commands
- [All `ed` commands](../README.md)
