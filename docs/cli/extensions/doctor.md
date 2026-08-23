# `ed extensions doctor`

Diagnoses setup and runtime problems for one extension or all sixteen.

```
ed extensions doctor [<id>] [--json]
```

Without an id, the human form prints a detailed report for every extension in
registry order and the JSON form is an ordered array. With an id, JSON is one
report object. `doctor` uses the same probe and JSON report as `status` and
`verify`.

Checks cover the stored enabled state, required and optional permissions,
required and optional tools, helper availability, platform capabilities,
configured machines and supported backend or session health. Checks that do not
apply are omitted, and checks behind a disabled extension are skipped.

```
ed extensions doctor
ed extensions doctor herdr
ed extensions doctor --json | jq '.[] | select(.state.phase == "failed")'
```

An unhealthy extension exits 0 with `verified: false`. This makes the command
safe for noninteractive agents that need the full remediation plan.

## Where to go next

- [`ed extensions status`](./status.md) for the compact table
- [`ed extensions setup`](./setup.md) for noninteractive setup
- [`ed extensions`](./README.md), the shared state and check contract
- [All `ed` commands](../README.md)
