# `ed usage projects copy-link`

Copy one usage repository link to the macOS pasteboard.

```
ed usage projects copy-link <repository> [--range <range>] [--json]
```

The same validated HTTP or HTTPS link used by the dashboard is copied. Missing
and malformed links fail without changing the pasteboard. A successful JSON
result contains `operation`, `repositoryID`, `value` and `performed`.

## Where to go next

- [`ed usage projects`](./projects.md), repository actions and drilldown
- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
