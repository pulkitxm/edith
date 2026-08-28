# `ed tools ls`

Lists the four tools with their state, version and reason.

Usage:

```
ed tools ls [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments, and there is nothing to filter or sort by:
the order is always `yt-dlp`, `claude`, `codex`, `quinjet`.

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
  },
  {
    "id": "quinjet",
    "installed": true,
    "name": "Quinjet",
    "path": "/opt/homebrew/bin/quinjet",
    "version": "quinjet 1.0.0",
    "why": "Powers local pull request review and live workspace changes."
  }
]
```

`id` is what `install` takes. `name` is the display name the Settings row shows,
which differs from the id for some tools. `why` is the sentence under that
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

For a broken tool, `path` still names the executable while `installed` is false
and `version` is null. A successful probe that prints no version uses the
executable name as its version fallback.

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
quinjet installed  quinjet 1.0.0                 Powers local pull request review and live workspace changes.
```

`STATE` is `installed`, `missing` or `broken`. A missing tool has no executable;
a broken tool exists but timed out or returned a non-zero status from
`--version`. Both leave `VERSION` blank:

```
$ ed tools ls
ID      STATE      VERSION                      WHY
yt-dlp  missing                                 Downloads YouTube audio into your Music library.
claude  installed  2.1.226 (Claude Code)        Includes Claude Code cloud sessions in Agent Usage.
codex   installed  codex-cli 0.146.0-alpha.9.2  Reads Codex session and weekly limits when that provider is enabled.
quinjet missing                                  Powers local pull request review and live workspace changes.
```

Behaviour: `ls` reads no settings, posts no notification and needs neither the
main window nor the menu bar helper. It writes
`~/Library/Application Support/Edith`, which assembling the PATH creates when it
is not already there, and `tool-versions.json` inside it, which is the version
cache. The four tools are probed concurrently, one task each, and a tool with
no cached version, or one whose cached stamp no longer matches the resolved
executable's path, filesystem identity, size or modification time, is run once,
with stdin on `/dev/null` and stderr discarded, and waited for, so a cold run is
only as slow as the slowest `--version` on the machine. This follows symlinks,
so replacing a package-managed target invalidates the cache even when its PATH
entry does not change. Each probe stops after five seconds, and only exit status
0 counts as installed.

While it probes it says so. A single spinner line on stderr reads
`probing 4 tools`, carries the seconds elapsed, is rewritten in place and is
erased before the table lands, so it leaves nothing in the transcript. It is
skipped entirely when stderr is not a terminal, when `--json` is passed, or when
`NO_COLOR` is set or `TERM` is `dumb`: stdout is the same either way.

## Where to go next

- [`ed tools`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
