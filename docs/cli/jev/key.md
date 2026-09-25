# `ed jev key`

Stores or removes the TypeSafe API key Edith uses for every Jev feature. The
same action is Save and Remove key in Settings > Jev.

```
ed jev key show [--json]
printf %s "$KEY" | ed jev key set [--json]
ed jev key clear [--yes] [--json]
```

A bare `ed jev key` runs `show`, which reports whether a key is saved and its
last four characters, never the key itself.

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--yes` | flag | off | `clear` only: remove the key; without it nothing changes |
| `--json` | flag | off | Emit JSON on stdout |

`set` reads the key from stdin so it never appears in process arguments or
shell history, saves it in the background agent's Keychain item, then probes it
and prints the resulting status. `clear` without `--yes` prints
`{"applied": false}` and changes nothing.

- [`ed jev`](./README.md)
- [All command groups](../README.md)
