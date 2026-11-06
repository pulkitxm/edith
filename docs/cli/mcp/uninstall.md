# `ed mcp uninstall`

[CLI reference](../README.md) | [MCP](./README.md)

Remove Edith's MCP server from a coding agent.

```sh
ed mcp uninstall --client <claude|codex|cursor|vscode|all> [--dry-run] [--command <path>] [--json]
```

It undoes [`ed mcp install`](./install.md) with the same rules, and Settings >
Agents runs the same code when you press Disconnect.

| Client | How it is removed |
| --- | --- |
| `claude` | `claude mcp remove --scope user edith` |
| `codex` | `codex mcp remove edith`, or a direct edit of `~/.codex/config.toml` when `codex` is not installed or too old |
| `cursor` | `mcpServers.edith` is deleted from `~/.cursor/mcp.json` |
| `vscode` | `servers.edith` is deleted from its user `mcp.json` |

Claude Code's own settings file is never edited. When the `claude` command is not
installed, the exact `claude mcp remove` line is printed instead, and the command
exits 1 if Claude Code was named with `--client claude`. A client without an
`edith` entry is left alone.

`--dry-run` prints what would change and changes nothing. An edited file is first
copied to `<name>.edith-backup`, and other servers and settings are kept. A file
that is not plain JSON is left untouched and the command exits 1. Restart the
client afterwards.

`--json` reports the same shape as `ed mcp install --json`, with `action` set to
`removed`, `unchanged`, `skipped` or `manual`.

## Related

- [`ed mcp install`](./install.md)
- [`ed mcp status`](./status.md)
- [`ed mcp`](./README.md)
