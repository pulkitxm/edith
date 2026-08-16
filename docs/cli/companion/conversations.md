# `ed companion conversations`

Lists conversations newest-first, or replays one in full when an id is given.

Usage:

```
ed companion conversations [<id>] [--limit <n>] [--json] [--endpoint <url>]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--limit` | positive integer | `20` | How many conversations to list. |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | resolution order | Uses this Companion API base URL. |

Without an id the JSON is an array of
`{id, title, createdAt, lastActiveAt, messageCount, lastMessage}`; with an id it
is one `{id, title, createdAt, messages}` object whose messages carry `role`,
`content`, `citations`, `model` and `createdAt`.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
