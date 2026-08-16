# `ed companion export`

Saves everything the companion remembers into a directory you choose: one
`bundle.json` holding episodes, observations, conversations, beliefs, claims,
facts, core memory and the non-secret reasoner settings, plus, with
`--include-media`, a `media/` directory of the original voice notes, PDFs,
images and videos.

Usage:

```
ed companion export <directory> [--include-media] [--json] [--endpoint <url>]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<directory>` | path | required | Where the bundle is written. Created if missing; `~` expands. |
| `--include-media` | flag | off | Also download every media file behind the episodes. |
| `--json` | flag | off | Emit JSON on stdout. |
| `--endpoint` | URL | resolution order | Companion API base URL. |

Examples:

```
ed companion export ~/backups/companion
ed companion export ~/backups/companion --include-media
ed companion export /tmp/before-wipe --json
```

Tokens and API keys never leave the companion: the bundle carries the reasoner
provider, URL and model, but not its key and not the connector tokens. Without
`--include-media` the bundle still lists every media file it left behind, and
the command says how many stayed, so a later `--include-media` run completes
the backup. The bundle restores with
[`ed companion import`](./import.md), and importing is idempotent, so exporting
before a risky operation is cheap insurance. Media files land as
`media/<sha256>-<name>`, which is exactly the layout import expects.

## Where to go next

- [`ed companion import`](./import.md), the other half
- [`ed companion wipe`](./wipe.md), what to export before
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
