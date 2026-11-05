# `ed mcp status`

[CLI reference](../README.md) | [MCP](./README.md)

Show which agent clients have Edith's MCP server registered.

```sh
ed mcp status [--command <path>] [--json]
```

Each client is `registered`, `registered, different command` (the entry points at
another `ed`, such as a moved app), `not registered`, or `config not readable`.
Run [`ed mcp install`](./install.md) to add or repair an entry.

## Related

- [`ed mcp install`](./install.md)
- [`ed mcp`](./README.md)
