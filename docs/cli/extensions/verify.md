# `ed extensions verify`

Runs every readiness check for one extension without changing anything.

```
ed extensions verify <id> [--json]
```

The human form prints the readiness phase, runtime phase, and summary followed
by every check, its status and its detail. A failed check prints a recovery
command when one is available. The JSON form contains `id`, `title`, `verified`,
`state`, `checks`, and `remediation`.

`verified` is true only when the extension is enabled and every required check
passes. False is a valid report and exits 0. Unknown extension ids exit 3.

```
ed extensions verify quinjet
ed extensions verify calendar --json
ed extensions verify machines --json | jq '{verified, state, remediation}'
```

## Where to go next

- [`ed extensions setup`](./setup.md) to enable an extension and plan setup
- [`ed extensions doctor`](./doctor.md) to diagnose the complete registry
- [`ed extensions`](./README.md), the shared state and check contract
- [All `ed` commands](../README.md)
