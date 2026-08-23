# `ed extensions setup`

Enables one extension and reports every setup step that remains.

```
ed extensions setup <id> [--dry-run] [--install-tools] [--json]
```

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--dry-run` | flag | off | Project the enabled state without writing settings or installing tools |
| `--install-tools` | flag | off | Install missing required tools without prompting |
| `--json` | flag | off | Emit the setup result and readiness report as JSON |

The command is noninteractive. It does not open the app, request a permission,
create a machine, or start a backend session. Those steps appear as failed
checks with actionable recovery commands. Tool installation happens only when
`--install-tools` is explicit. The operation and the Extensions pane use the
same provisioning executor and preserve per-tool failures without rolling back
the enabled extension.

JSON includes `dryRun`, `changed`, `plannedTools`, `installedTools`,
`installFailures`, and `report`. A tool installation failure is represented in
`installFailures`, and incomplete readiness is represented by
`report.verified: false`.

```
ed extensions setup quinjet --dry-run --json
ed extensions setup quinjet --install-tools
ed extensions setup calendar --json
```

## Where to go next

- [`ed extensions verify`](./verify.md) to rerun every check
- [`ed permissions`](../permissions/README.md) to grant required access
- [`ed tools`](../tools/README.md) to inspect managed tools
- [All `ed` commands](../README.md)
