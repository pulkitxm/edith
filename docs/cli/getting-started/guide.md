# `ed guide`

Prints the built-in manual, the same text the app ships to explain itself.

```
ed guide [<topic>]
```

Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<topic>` | `claude`, case-insensitive | none, meaning the full manual | Which text to print |

There is no `--json`. The output is prose, it is static, and it needs neither
the app, the network, nor a machine.

Examples

```
ed guide
ed guide claude
ed guide | less
```

`ed guide claude` prints a section you can paste into any repository's
`CLAUDE.md` so an agent working there knows `ed` exists, knows every read
command takes `--json`, and knows the exit codes are worth gating on.

Any topic other than `claude` exits 3 and says what the two options are:

```
$ ed guide nope
error: no guide topic named nope
hint: try `ed guide` or `ed guide claude`
```

## Where to go next

- [Getting started with `ed`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
