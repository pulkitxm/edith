# `ed mcp install`

[CLI reference](../README.md) | [MCP](./README.md)

Register Edith's MCP server with a coding agent.

```sh
ed mcp install --client <claude|codex|cursor|vscode|all> [--dry-run] [--command <path>] [--json]
```

The entry is named `edith` and runs `ed mcp` from the installed app, so it keeps
working after `ed install` is run or removed. `--command` overrides that path.

| Client | File | Format |
| --- | --- | --- |
| `claude` | `~/.claude.json` | JSON, `mcpServers.edith` |
| `codex` | `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`) | TOML, `[mcp_servers.edith]` |
| `cursor` | `~/.cursor/mcp.json` | JSON, `mcpServers.edith` |
| `vscode` | `~/Library/Application Support/Code/User/mcp.json` | JSON, `servers.edith` |

`--dry-run` prints the entry and changes nothing. An existing file is copied to
`<name>.edith-backup` before it is edited, and other servers and settings are kept.
A file that is not plain JSON (comments, for example) or a TOML table Edith cannot
edit safely is left untouched: the command exits 1 and prints the exact entry to
paste. Restart the client to load the server.

## Related

- [`ed mcp status`](./status.md)
- [`ed mcp`](./README.md)
