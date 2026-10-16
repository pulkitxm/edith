# `ed companion claims`

Lists the extracted claims, newest first, with the latest verdict where one exists.

Usage:

```
ed companion claims [--json] [--endpoint <url>] [--limit <n>]
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
    "assertedAt": "2026-03-14T00:00:00Z",
    "claimType": "progress",
    "id": "77b7a0e2-4a37-4b3f-8b0f-0a9d1c2c8e21",
    "statement": "Shipped the auth refactor this week.",
    "testable": true,
    "verdict": "corroborated",
    "verdictNote": "Commits to the auth paths land in the same week."
  }
]
```

`verdict` and `verdictNote` are null until a corroboration pass has judged the claim.

Examples:

```
$ ed companion claims --limit 1
1. [progress] -> corroborated Shipped the auth refactor this week.
   Commits to the auth paths land in the same week.
```

Behaviour: read-only.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
