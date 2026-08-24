# `ed usage projects open`

Open one usage repository in the default browser.

```
ed usage projects open <repository> [--range <range>] [--json]
```

Only repository records with a valid HTTP or HTTPS link can be opened. Missing
and malformed links fail without launching anything. A successful JSON result
contains `operation`, `repositoryID`, `value` and `performed`, where `value` is
the validated link and `performed` is `true`.

## Where to go next

- [`ed usage projects`](./projects.md), repository actions and drilldown
- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
