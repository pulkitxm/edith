# `ed version`

Prints the CLI version, and with `--json` whether Edith is running.

```
ed version [--json]
```

Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the bare version string |

`--json` shape:

```json
{
  "appRunning": true,
  "version": "1.0.0"
}
```

Examples

```
ed version
ed version --json
ed --version
```

`appRunning` is about the menu bar helper, bundle id
`com.pulkit.edith.statusbar`, not the main window, because the helper is what
answers the commands that need the app. This is the polite way to find out: it
reports the state and exits 0 either way, where a command that actually needs
the app exits 4.

`ed --version` prints the same string through the argument parser. The version
is declared on the root command, so it is inherited: `ed schema --version` and
`ed machines ls --version` also print `1.0.0` and exit 0.

## Where to go next

- [Getting started with `ed`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
