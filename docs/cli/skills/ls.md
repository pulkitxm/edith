# `ed skills ls`

Lists the Edith skill library and the agents that can receive an install.

[`ed skills`](./README.md)

Usage:

```
ed skills ls [--all-agents] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--all-agents` | flag | off | Includes every supported agent, not only the ones detected on this Mac. |
| `--json` | flag | off | Emits one JSON document on stdout. |

`ed skills` runs this command. It reads the bundled catalog and local agent
directories. It does not download skill files.

`--json` shape:

```json
{
  "agents": [{ "detected": true, "id": "cursor", "name": "Cursor" }],
  "skills": [
    {
      "detail": "Discover connected machines.",
      "id": "edith-remote-work",
      "name": "Edith Remote Work",
      "summary": "Your harness here. Your projects on any Edith machine."
    }
  ]
}
```

Examples:

```
ed skills ls
ed skills ls --all-agents
ed skills ls --json
```

See also:

- [`ed skills preview`](./preview.md)
- [`ed skills`](./README.md)
- [`ed`](../README.md)
