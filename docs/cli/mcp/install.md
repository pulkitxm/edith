# `ed mcp install`

[CLI reference](../README.md) | [MCP](./README.md)

Register Edith's MCP server with a coding agent. The Connect buttons in Settings >
Agents run the same code.

```sh
ed mcp install --client <claude|codex|cursor|vscode|all> [--dry-run] [--command <path>] [--json]
```

The server is named `edith` and runs `ed mcp` from the installed app, so it keeps
working whether or not `ed install` put `ed` on your `PATH`. `--command` points it
at another absolute path instead.

| Client | How it is registered | Where it lands |
| --- | --- | --- |
| `claude` | `claude mcp add --scope user edith -- <ed> mcp` | `mcpServers.edith` in `~/.claude.json` |
| `codex` | `codex mcp add edith -- <ed> mcp`, or a direct edit when `codex` is not installed or too old | `[mcp_servers.edith]` in `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`) |
| `cursor` | direct edit | `mcpServers.edith` in `~/.cursor/mcp.json` |
| `vscode` | direct edit | `servers.edith` in `~/Library/Application Support/Code/User/mcp.json` |

`--client all` registers every client found on this Mac and skips the rest: a
client counts as found when its command is installed or its settings folder
exists. Naming one client writes its entry even when the client is not found.

Claude Code's own settings file is never edited. When the `claude` command is not
installed, the exact `claude mcp add` line is printed instead, and the command
exits 1 if Claude Code was named with `--client claude`. An entry that already
points at this `ed` is left alone, and one pointing at another `ed` is replaced.

`--dry-run` prints the command or entry and changes nothing. An edited file is
first copied to `<name>.edith-backup`, and other servers and settings are kept. A
file that is not plain JSON (comments, for example) or a TOML table Edith cannot
edit safely is left untouched: the command exits 1 and prints the exact entry to
paste. Restart the client to load the server, then ask the agent to call
`edith_catalog`.

`--json` reports `command`, `dryRun` and one object per client with `client`,
`path`, `action` (`created`, `updated`, `unchanged`, `skipped`, `manual` or
`notFound`; [`ed mcp uninstall`](./uninstall.md) adds `removed`), `applied`, `run` (the client command, or `null`), `snippet`, `note`
and `backup`.

## Related

- [`ed mcp uninstall`](./uninstall.md)
- [`ed mcp status`](./status.md)
- [`ed mcp`](./README.md)
