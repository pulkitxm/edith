# `ed tools ls`

Lists the three tools with their state, version and reason.

Usage:

```
ed tools ls [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments, and there is nothing to filter or sort by:
the order is always `yt-dlp`, `claude`, `codex`.

`--json` shape, an array with one object per tool:

```json
[
  {
    "id": "yt-dlp",
    "installed": true,
    "name": "yt-dlp",
    "path": "/Users/pulkit/Library/Application Support/Edith/bin/yt-dlp",
    "version": "2026.07.04",
    "why": "Downloads YouTube audio into your Music library."
  },
  {
    "id": "claude",
    "installed": true,
    "name": "Claude Code",
    "path": "/Users/pulkit/.local/bin/claude",
    "version": "2.1.226 (Claude Code)",
    "why": "Includes Claude Code cloud sessions in Agent Usage."
  },
  {
    "id": "codex",
    "installed": true,
    "name": "Codex",
    "path": "/Users/pulkit/.local/bin/codex",
    "version": "codex-cli 0.146.0-alpha.9.2",
    "why": "Reads Codex session and weekly limits when that provider is enabled."
  }
]
```

`id` is what `install` takes. `name` is the display name the Settings row shows,
which differs from the id for two of the three. `why` is the sentence under that
name in the same row. A tool that is not installed keeps every key and nulls the
two that have no answer:

```json
{
  "id": "yt-dlp",
  "installed": false,
  "name": "yt-dlp",
  "path": null,
  "version": null,
  "why": "Downloads YouTube audio into your Music library."
}
```

`version` is also `null` when the tool is installed but printed nothing on
stdout for `--version`.

Examples:

```
ed tools ls
ed tools ls --json
ed tools ls --json | jq -r '.[] | select(.installed | not) | .id'
```

The table is four columns, and the last one is not padded:

```
$ ed tools ls
ID      STATE      VERSION                      WHY
yt-dlp  installed  2026.07.04                   Downloads YouTube audio into your Music library.
claude  installed  2.1.226 (Claude Code)        Includes Claude Code cloud sessions in Agent Usage.
codex   installed  codex-cli 0.146.0-alpha.9.2  Reads Codex session and weekly limits when that provider is enabled.
```

`STATE` is `installed` or `missing`, and a missing tool leaves `VERSION` blank
rather than printing a placeholder:

```
$ ed tools ls
ID      STATE      VERSION                      WHY
yt-dlp  missing                                 Downloads YouTube audio into your Music library.
claude  installed  2.1.226 (Claude Code)        Includes Claude Code cloud sessions in Agent Usage.
codex   installed  codex-cli 0.146.0-alpha.9.2  Reads Codex session and weekly limits when that provider is enabled.
```

Behaviour: `ls` reads no settings, posts no notification and needs neither the
main window nor the menu bar helper. It writes
`~/Library/Application Support/Edith`, which assembling the PATH creates when it
is not already there, and `tool-versions.json` inside it, which is the version
cache. The three tools are probed concurrently, one task each, and a tool with
no cached version, or one whose cached stamp no longer matches the binary's size
and modification time, is run once, with stdin on `/dev/null` and stderr
discarded, and waited for, so a cold run is only as slow as the slowest
`--version` on the machine and there is no timeout. A tool's exit status is ignored: presence is decided by the file being
executable, and the version is whatever first line came back.

While it probes it says so. A single spinner line on stderr reads
`probing 3 tools`, carries the seconds elapsed, is rewritten in place and is
erased before the table lands, so it leaves nothing in the transcript. It is
skipped entirely when stderr is not a terminal, when `--json` is passed, or when
`NO_COLOR` is set or `TERM` is `dumb`: stdout is the same either way.

## Where to go next

- [`ed tools`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
