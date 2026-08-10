# `ed companion corroborate`

Judges unchecked testable claims against the observations recorded around when they were made.

Usage:

```
ed companion corroborate [--json] [--endpoint <url>]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | environment or local default | Uses this Companion API base URL. |

`--json` shape:

```json
{
  "claimsChecked": 2,
  "contradicted": 0,
  "corroborated": 1,
  "unclear": 1
}
```

Examples:

```
$ ed companion corroborate
checked 2 claims: 1 corroborated, 0 contradicted, 1 unclear
```

Behaviour: up to ten unchecked `progress`, `commitment` and `fact` claims are compared against the observations within four days of their assertion. The verdict is `corroborated`, `contradicted` or `unclear` with a one-line note; missing records always read as `unclear`, never as contradiction. Needs a reasoning provider; exit 4 without one.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
