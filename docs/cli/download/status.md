# `ed download status`

Summarizes every lifecycle state in the persisted download queue.

Usage:

```
ed download status [--json]
```

`status` is a stable file read. It works whether Edith is running or closed.
The plain table reports `total`, `active`, `queued`, `resolving`, `downloading`,
`done`, `failed` and `interrupted`. `active` is the sum of queued, resolving and
downloading records.

JSON output is one object with the same integer fields:

```json
{
  "active": 2,
  "done": 4,
  "downloading": 1,
  "failed": 1,
  "interrupted": 0,
  "queued": 1,
  "resolving": 0,
  "total": 7
}
```

An empty queue is successful and reports zero for every field.

## Where to go next

- [`ed download`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
