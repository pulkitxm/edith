# `ed usage projects show`

Show one repository and its folder-level usage drilldown.

```
ed usage projects show <repository> [--range <range>] [--json]
```

The repository can be its stable identity, visible name or full URL. The plain
report includes the identity, link, total cost and tokens, then a table of every
folder with its machine, path, cost and tokens. JSON uses the same stable object
shape as one item from `ed usage projects list --json`.

Use the stable identity when two repositories have the same visible name.

## Where to go next

- [`ed usage projects`](./projects.md), repository actions and drilldown
- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
