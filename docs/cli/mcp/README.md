# `ed mcp`

`ed mcp` serves every Edith operation to an agent over MCP stdio.
[`ed mcp install`](./install.md) registers it with Claude Code, Codex, Cursor and
VS Code in one step, and [`ed mcp uninstall`](./uninstall.md) removes it again.

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

The easiest way is Settings > Connect agents in the Edith window, also reachable from the
Get Started card on Home and from the last onboarding step. It lists Claude Code,
Codex, Cursor and VS Code, says whether each one is installed on this Mac and
whether it is Connected, Not connected, Points at another Edith (the entry runs a
different `ed`, such as a moved app or a development build) or Needs manual setup.
Connect, Connect all and Disconnect run the same code as the commands below, and a
step Edith cannot do for you shows the exact snippet with a Copy button. Open it
from a terminal with `ed app reveal settings --tab mcp`.

From a terminal, one command registers Edith with every agent client found on this Mac, using the
`ed` inside the installed app:

```
ed mcp install --client all --dry-run
ed mcp install --client all
ed mcp status
```

Claude Code is registered through its own CLI, so this runs:

```sh
claude mcp add --scope user edith -- /Applications/Edith.app/Contents/MacOS/ed mcp
```

Codex is registered with `codex mcp add` when the `codex` command is installed,
and otherwise gets this block in `~/.codex/config.toml`:

```toml
[mcp_servers.edith]
command = "/Applications/Edith.app/Contents/MacOS/ed"
args = ["mcp"]
```

Cursor gets `mcpServers.edith` in `~/.cursor/mcp.json`, and VS Code gets
`servers.edith` with `"type": "stdio"` in its user `mcp.json`. See
[`ed mcp install`](./install.md), [`ed mcp uninstall`](./uninstall.md) and
[`ed mcp status`](./status.md). Restart the client afterwards.

## How an agent should use it

The server's `initialize` instructions spell out the same order.

1. Discover. Call `edith_catalog`. It lists every extension with its status
   (`enabled`, `installed`, `available`), tagline, summary and example `ed`
   commands. Pass `query`, `status` or `id` to narrow it; `id` also returns the
   extension's steps.
2. Call. Use the matching `edith_*` tool. Command tools take an `arguments` array
   holding the words that follow the command, so `ed usage limits --refresh` is
   `edith_usage_limits` with `{"arguments": ["--refresh"]}`. Tools exist only for
   enabled extensions.
3. Install only when needed. If the extension is available, call
   `edith_extensions_install` with `{"arguments": ["<id>"]}`. Installing changes
   the Mac, so it previews until `confirm` is true. Ask the user, then confirm.
   The server sends `notifications/tools/list_changed` once the set of tools
   changes; list tools again.
4. Call `edith_app_navigate` with `{"arguments": ["<id>"]}` to show the user the
   extension's page.

`extensions install`, `update`, `enable`, `disable` and `remove` all follow the
preview and `confirm` rule, in addition to the destructive routes above.

The server accepts protocol versions `2025-11-25`, `2025-06-18`, `2025-03-26`
and `2024-11-05`, answering with the client's version when it is one of them.

## Resources

`resources/list` and `resources/read` serve the same guidance as markdown:

| URI | Content |
| --- | --- |
| `edith://guide` | The full [`ed guide`](../getting-started/guide.md) manual |
| `edith://guide/agent` | `ed guide agent`, repository instructions for agents |
| `edith://guide/mcp` | `ed guide mcp`, this flow in short form |
| `edith://extensions/<id>` | One extension's tagline, summary, steps, examples and commands |

Reading a URI that is not listed fails with error code `-32002` (resource not
found) and the URI in `data.uri`.

## Errors

| Code | When |
| --- | --- |
| `-32700` | The line is not JSON |
| `-32600` | Not a JSON-RPC request, or a request sent before `initialize` |
| `-32601` | Unknown method |
| `-32602` | Unknown tool or invalid arguments |
| `-32603` | Edith could not be reached or a provider failed |
| `-32002` | Unknown resource URI |

A command that runs and fails is not a protocol error: the tool result carries
the command's stderr with `isError: true`, and so does `edith_catalog` for an
unknown `id`.

## Where to go next

- [`ed agent`](../agent/README.md), the process behind most of these tools
- [Conventions and contracts](../conventions.md), for the JSON guarantee
- [All `ed` commands](../README.md)
