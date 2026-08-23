# `ed usage projects`

Inspect the repository hierarchy behind the dashboard project drilldown.

```
ed usage projects <command>
```

With no command, this group runs `ed usage projects list`.

## Commands

| Command | What it does |
| --- | --- |
| `ed usage projects list` | List repository totals in descending cost order |
| `ed usage projects show <repository>` | Show one repository and every matching folder |
| `ed usage projects open <repository>` | Open its HTTP repository link in the browser |
| `ed usage projects copy-link <repository>` | Copy its HTTP repository link |
| `ed usage projects copy-chat <chat-id>` | Copy a chat identifier from the dashboard drilldown |

A repository argument can be its stable identity, visible name or full URL. A
visible name shared by several repositories is rejected as ambiguous. Use the
stable identity from `list --json` to select it exactly.

## Where to go next

- [`ed usage projects list`](./projects-list.md)
- [`ed usage projects show`](./projects-show.md)
- [`ed usage projects open`](./projects-open.md)
- [`ed usage projects copy-link`](./projects-copy-link.md)
- [`ed usage projects copy-chat`](./projects-copy-chat.md)
- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
