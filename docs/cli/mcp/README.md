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
forgets to confirm gets the preview, never the change.

The database tools from [`ed database mcp`](../database/mcp.md) are served
here too, so one registration covers both surfaces.

## Registering it

Onboarding writes the entry for you. To do it by hand, add this to Claude
Code's configuration:

```json
{
  "mcpServers": {
    "edith": { "command": "ed", "args": ["mcp"] }
  }
}
```

For Codex, add the equivalent block to its configuration:

```toml
[mcp_servers.edith]
command = "ed"
args = ["mcp"]
```

## Where to go next

- [`ed agent`](../agent/README.md), the process behind most of these tools
- [Conventions and contracts](../conventions.md), for the JSON guarantee
- [All `ed` commands](../README.md)
