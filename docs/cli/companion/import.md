# `ed companion import`

Restores a bundle written by [`ed companion export`](./export.md): episodes,
observations, conversations, beliefs, claims, facts, core memory, the
non-secret reasoner settings, and any media files sitting next to the bundle.

Usage:

```
ed companion import <path> [--json] [--endpoint <url>]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<path>` | file or directory | required | The `bundle.json`, or the export directory holding it. |
| `--json` | flag | off | Emit JSON on stdout. |
| `--endpoint` | URL | resolution order | Companion API base URL. |

Examples:

```
ed companion import ~/backups/companion
ed companion import ~/backups/companion/bundle.json --json
```

Importing merges rather than replaces: every record keeps the id it was
exported with, records that already exist are skipped, and nothing is deleted,
so running the same import twice changes nothing the second time. Settings are
only filled in where the companion has none, so a configured reasoner is never
clobbered by a restore. A `media/` directory beside the bundle is restored
file by file after the rows land. Episodes arrive unembedded and the companion
starts indexing them in the background; the command reports how many are
queued. A file that is not a companion export, or one written by a newer
companion, is refused before anything is touched.

## Where to go next

- [`ed companion export`](./export.md), the other half
- [`ed companion status`](./status.md), see the counts after
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
