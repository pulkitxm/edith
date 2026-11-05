# `ed mcp`

`ed mcp` serves every Edith operation to an agent over MCP stdio. It is the
server the onboarding "Connect your agents" screen registers with Claude Code,
and the one to point Codex at.

```
ed mcp
```

Each registered operation becomes one tool named after its route, so
`ed usage limits` is `edith_usage_limits` and `ed machines ls` is
`edith_machines_ls`. A tool takes an `arguments` array holding exactly what the
route accepts on the command line, runs it with `--json`, and returns the JSON
document unchanged. Anything the CLI can do, an agent can now do, with the same
contract and the same exit semantics.

Destructive routes keep the CLI's safety model. They preview by default and
apply only when the call passes `confirm`, which adds `--yes`. An agent that
forgets to confirm gets the preview, never the change, and a call that slips
`--yes` into `arguments` is refused, so `confirm` is the only way to apply.

While a TypeSafe key is saved in Settings > Jev, the server also lists
`edith_find`. It takes a plain-language `request` and returns the five likeliest
tools with their summaries and probabilities. See [`ed jev`](../jev/README.md).

The database tools from [`ed database mcp`](../database/mcp.md) are served
here too, so one registration covers both surfaces.

## Registering it

One command registers Edith with a client, using the `ed` inside the installed app:

```
ed mcp install --client claude --dry-run
ed mcp install --client claude
ed mcp install --client all
ed mcp status
```

See [`ed mcp install`](./install.md) and [`ed mcp status`](./status.md). Restart the
client afterwards. To do it by hand, add this to Claude Code's `~/.claude.json`:

```json
{
  "mcpServers": {
    "edith": { "type": "stdio", "command": "/Applications/Edith.app/Contents/MacOS/ed", "args": ["mcp"] }
  }
}
```

For Codex, add the equivalent block to `~/.codex/config.toml`:

```toml
[mcp_servers.edith]
command = "/Applications/Edith.app/Contents/MacOS/ed"
args = ["mcp"]
```

## How an agent should use it

1. Call `edith_catalog`. It lists every extension with its status (`enabled`,
   `installed`, `available`), tagline, summary and example `ed` commands. Pass
   `query`, `status` or `id` to narrow it; `id` also returns the extension's steps.
2. Call the matching `edith_*` tool. Tools exist only for installed, enabled
   extensions.
3. If the extension is available but not installed, call `edith_extensions_install`
   with `arguments: ["<id>"]`. Installing changes the Mac, so it previews until
   `confirm` is true. Ask the user, then confirm. The server sends
   `notifications/tools/list_changed` once the set of tools changes; list tools again.
4. Call `edith_app_navigate` with `arguments: ["<id>"]` to show the user the
   extension's page.

`extensions install`, `update`, `enable`, `disable` and `remove` all follow the
preview and `confirm` rule, in addition to the destructive routes above.

## Resources

`resources/list` and `resources/read` serve the same guidance as markdown:

| URI | Content |
| --- | --- |
| `edith://guide` | The full [`ed guide`](../getting-started/guide.md) manual |
| `edith://guide/agent` | `ed guide agent`, repository instructions for agents |
| `edith://guide/mcp` | `ed guide mcp`, this flow in short form |
| `edith://extensions/<id>` | One extension's tagline, summary, steps, examples and commands |

## Where to go next

- [`ed agent`](../agent/README.md), the process behind most of these tools
- [Conventions and contracts](../conventions.md), for the JSON guarantee
- [All `ed` commands](../README.md)
