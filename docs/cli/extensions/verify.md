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
Verification includes the extension's live adapter, so a valid preference and
running helper do not hide corrupt storage, a missing service, invalid
configuration, or an empty content source.

```
ed extensions verify quinjet
ed extensions verify calendar --json
ed extensions verify machines --json | jq '{verified, state, remediation}'
```

## Where to go next

- [`ed extensions setup`](./setup.md) to enable an extension and plan setup
- [`ed extensions doctor`](./doctor.md) to diagnose the complete registry
- [Extension runtime detection](./runtime-detection.md) for adapter inputs and
  recovery commands
- [`ed extensions`](./README.md), the shared state and check contract
- [All `ed` commands](../README.md)
