# `ed herdr attach`

Attaches the current terminal to one live Herdr pane.

```
ed herdr attach <pane> [--machine <name>] [--session <name>] [--json]
```

`--machine` and `--session` disambiguate matches in the same way as
`ed herdr command`. The plain form hands the terminal to Herdr locally or to
SSH for a remote pane. Its exit status is the attached process status.

`--json` is non-interactive. It resolves the pane and prints the exact
`executable`, `arguments`, command and target fields with `attached: false`.
This makes automation safe without pretending that an interactive session ran.

```
ed herdr attach w3:p1N --machine local
ed herdr attach w3:p1N --machine tuf --json
```

Unknown or ambiguous panes exit 3. An unavailable machine exits 4.

## Where to go next

- [`ed herdr command`](./command.md), print the portable attach line
- [`ed herdr`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
