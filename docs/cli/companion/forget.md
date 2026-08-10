# `ed companion forget`

Deletes a conversation and every message in it.

Usage:

```
ed companion forget <id> [--json] [--endpoint <url>]
```

`--json` shape: `{"deleted": "<conversation id>"}`. Unknown ids exit `4` with
the backend's `no such conversation` detail.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
