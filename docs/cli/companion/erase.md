# `ed companion erase`

Deletes one episode: its chunks, its claims and their corroborations, its
mention in belief evidence, and, when nothing else shares the source, the
original file in the vault.

Usage:

```
ed companion erase <id> --yes [--json] [--endpoint <url>]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<id>` | episode UUID | required | The episode to erase. |
| `--yes` | flag | off | Actually delete. Without it the command refuses and nothing happens. |
| `--json` | flag | off | Emit JSON on stdout. |
| `--endpoint` | URL | resolution order | Companion API base URL. |

Examples:

```
ed companion episode 4ec1e64d-cb19-48e5-baef-0f098498ce20
ed companion erase 4ec1e64d-cb19-48e5-baef-0f098498ce20 --yes
```

Erasing cannot be undone, which is why `--yes` is mandatory: without it the
command exits 2 and tells you to read the episode first. Beliefs formed from
the episode survive, but the episode's id is removed from their evidence, so
`ed companion why` stops citing it. An id the companion does not know exits 1
with `no such episode`. This is the one-record cousin of
[`ed companion wipe`](./wipe.md); for a conversation rather than an episode,
[`ed companion forget`](./forget.md) is the right verb.

`--json` is
`{erased,claimsDeleted,chunksDeleted,sourceDeleted,vaultFileRemoved}`.
`sourceDeleted` and `vaultFileRemoved` are false when another episode still
uses the same source. Export the memory, including media, before erasing if the
episode might be needed later.

## Where to go next

- [`ed companion episode`](./episode.md), read it before erasing it
- [`ed companion wipe`](./wipe.md), all of it at once
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
