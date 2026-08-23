# `ed companion forget`

Deletes a conversation and every message in it.

Usage:

```
ed companion forget <id> [--json] [--endpoint <url>] [--yes]
```

Without `--yes`, this prints the conversation id as the exact target and does
not contact the backend. JSON includes `applied: false`, `changed: false`, and
`targets`. With `--yes`, `deleted` holds the backend-confirmed id. Unknown ids
then exit `1` with the backend's `no such conversation` detail.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
