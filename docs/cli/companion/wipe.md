# `ed companion wipe`

Deletes the companion's entire memory: every episode, source, observation,
belief, claim, fact, conversation, entity, hypothesis and the vault files
behind them. The reasoner configuration, connector tokens and machine records
survive, so the companion is empty but still set up.

Usage:

```
ed companion wipe --yes [--json] [--endpoint <url>]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--yes` | flag | off | Actually wipe. Without it the command refuses and nothing happens. |
| `--json` | flag | off | Emit JSON on stdout. |
| `--endpoint` | URL | resolution order | Companion API base URL. |

Examples:

```
ed companion export ~/backups/companion --include-media
ed companion wipe --yes
```

Wiping cannot be undone, which is why `--yes` is mandatory and why the refusal
names [`ed companion export`](./export.md) as the step to take first. This
differs from `ed companion stack down --wipe` in what survives: `stack down
--wipe` destroys the containers and their volumes, models included, while
`wipe` empties the database and vault through the API and leaves the stack
running and configured. After a wipe, [`ed companion import`](./import.md) of
an export brings the memory back.

The API requires the literal confirmation `everything`; the CLI sends it only
after `--yes` passes. `--json` is
`{episodesDropped,sourcesDropped,observationsDropped,conversationsDropped,
beliefsDropped,vaultCleared}`. `vaultCleared: false` means at least one vault
directory could not be removed even though the database tables were already
truncated. Treat that result as a partial wipe and inspect the vault volume.

This command does not delete the export you made on this Mac. Verify that the
backup's `mediaFailed` array is empty before relying on it for recovery.

## Where to go next

- [`ed companion export`](./export.md), do this first
- [`ed companion import`](./import.md), the road back
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
