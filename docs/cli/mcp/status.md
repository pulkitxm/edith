# `ed mcp status`

[CLI reference](../README.md) | [MCP](./README.md)

Show which agent clients have Edith's MCP server registered. Settings > Agents
shows the same report as Connected, Points at another Edith, Not connected or
Needs manual setup.

```sh
ed mcp status [--command <path>] [--json]
```

Each client is `registered`, `registered, different command` (the entry points at
another `ed` or other arguments, such as a moved app), `not registered`, `client
not found` (neither its command nor its settings folder is on this Mac), or
`config not readable`. Claude Code is read from the user scope in
`~/.claude.json`. The last line names the one command to run next.

`--json` reports `command` and one object per client with `client`, `title`,
`path`, `configExists`, `clientFound`, `state` (`registered`, `outdated`,
`notRegistered` or `unreadable`) and the registered `command`.

## Related

- [`ed mcp install`](./install.md)
- [`ed mcp uninstall`](./uninstall.md)
- [`ed mcp`](./README.md)
