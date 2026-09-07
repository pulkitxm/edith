# `ed guide`

Prints the built-in manual, the same text the app ships to explain itself.

```
ed guide [<topic>] [--json]
```

Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<topic>` | `agent`, case-insensitive | none, meaning the full manual | Which text to print |

Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit the complete command, alias, argument, option and help catalog as JSON |

The full manual and the `agent` topic are static prose. `--json` emits the parser
catalog with `serializationVersion`, the root `command`, every nested
`subcommand`, aliases, positional arguments, flags, options, accepted values,
defaults and help text. It is the noninteractive discovery path for automation.
All three forms need neither the app, the network, a machine, nor a repository.

Examples

```
ed guide
ed guide agent
ed guide --json | jq '.command.subcommands[] | {name: .commandName, aliases}'
ed guide | less
```

`ed guide agent` prints a section you can paste into a repository instruction
file so an agent working there knows `ed` exists, can discover the complete
parser tree, can use structured output where advertised, and can inspect, set
up, verify, and recover all twenty-two extensions noninteractively.

Any topic other than `agent` exits 3 and lists the discovery forms:

```
$ ed guide nope
error: no guide topic named nope
hint: try `ed guide`, `ed guide agent`, or `ed guide --json`
```

Combining a topic with `--json` exits 2 with empty stdout because the structured
catalog applies to the full command tree, not one prose topic.

## Where to go next

- [Getting started with `ed`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
