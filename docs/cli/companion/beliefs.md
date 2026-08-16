# `ed companion beliefs`

Lists the beliefs the reflection pass has formed, newest first.

Usage:

```
ed companion beliefs [--json] [--endpoint <url>] [--limit <n>]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | resolution order | Uses this Companion API base URL. |
| `--limit` | 1 to 200 | 20 | How many to list. |

`--json` shape:

```json
[
  {
    "confidence": 0.7,
    "evidenceEpisodeIds": ["ade45706-c7e0-480c-9125-11503509bef2"],
    "firstFormed": "2026-08-09T16:20:11Z",
    "id": "3f7f7a68-0f4b-4f0f-9dd6-6cf2b1f7f0aa",
    "kind": "pattern",
    "statement": "Ships work in small, frequently pushed increments.",
    "status": "active"
  }
]
```

Each belief carries its `statement`, a `kind` of `pattern`, `preference` or `state`, the extractor's `confidence`, when it was `firstFormed`, the `evidenceEpisodeIds` it cites, and its `status`. Beliefs are never deleted, only superseded or retired.

Examples:

```
$ ed companion beliefs --limit 1
1. [pattern, 70%] Ships work in small, frequently pushed increments.
   evidence: 3 episodes, since 2026-08-09T16:20:11Z
```

Behaviour: read-only. An empty list suggests running `ed companion reflect` first.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
