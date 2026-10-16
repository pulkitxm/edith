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
| `--endpoint` | URL | resolution order | Uses this Companion API base URL. |

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

Behaviour: the reasoner reads up to ten episodes without claims and records
each assertion with a type (`fact`, `intention`, `commitment`, `progress`,
`self_assessment`, `prediction`, `preference`, `feeling`) and whether
independent records could test it. A missing reasoning provider is a backend
failure and exits 1. An unreachable companion endpoint exits 4.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
