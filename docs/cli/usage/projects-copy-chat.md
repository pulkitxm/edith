# `ed usage projects copy-chat`

Copy a chat identifier from the dashboard repository drilldown.

```
ed usage projects copy-chat <chat-id> [--json]
```

Chat identifiers are listed by `ed usage projects show <repository>` and complete
in supported shells after installing Edith's completions.

Whitespace around the identifier is removed. An empty identifier fails without
changing the pasteboard. A successful JSON result contains `operation`, a null
`repositoryID`, the copied identifier in `value`, and `performed` set to `true`.

## Where to go next

- [`ed usage projects`](./projects.md), repository actions and drilldown
- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
