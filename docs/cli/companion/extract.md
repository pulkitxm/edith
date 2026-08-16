# `ed companion extract`

Pulls the claims you made out of episodes that have none yet.

Usage:

```
ed companion extract [--json] [--endpoint <url>]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | environment or local default | Uses this Companion API base URL. |

`--json` shape:

```json
{
  "claimsExtracted": 4,
  "episodesConsidered": 3
}
```

Examples:

```
$ ed companion extract
considered 3 episodes, extracted 4 claims
```

Behaviour: the reasoner reads up to ten episodes without claims and records each assertion with a type (`fact`, `intention`, `commitment`, `progress`, `self_assessment`, `prediction`, `preference`, `feeling`) and whether independent records could test it. Needs a reasoning provider; exit 4 without one.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
