# `ed tools install`

Installs one tool, or reports that it is already there.

Usage:

```
ed tools install <tool> [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<tool>` | one of `yt-dlp`, `claude`, `codex`, or a display name: `yt-dlp`, `Claude Code`, `Codex` | required | Which tool to install. Matched case-insensitively against the id first, then against the display name. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

Matching is exact, not by prefix: `CODEX` and `Claude Code` both resolve, `cla`
and `ytdlp` do not and exit 3 with the three ids as the hint. A display name
with a space in it has to be quoted, or the shell hands `ed` a second
positional and ArgumentParser rejects it with exit 2 before any id is looked
up.

`--json` shape when the tool is already installed:

```json
{
  "changed": false,
  "id": "yt-dlp",
  "installed": true,
  "path": "/Users/pulkit/Library/Application Support/Edith/bin/yt-dlp"
}
```

`--json` shape when it was missing and the install ran:

```json
{
  "changed": true,
  "id": "yt-dlp",
  "installed": true,
  "version": "2026.07.04"
}
```

The two shapes are not the same object with different values. `path` exists only
on the already-installed branch and `version` only on the branch that did the
work, so branch on `changed`: `installed` is `true` in both, because a failed
install prints no JSON at all, only the error and the hint on stderr.

Examples:

```
ed tools install yt-dlp
ed tools install codex --json
ed tools install "Claude Code"
```

A tool that is already present is reported and left alone. The line goes to
stderr, so stdout stays empty and the exit code is 0:

```
$ ed tools install yt-dlp
yt-dlp is already at /Users/pulkit/Library/Application Support/Edith/bin/yt-dlp
```

A missing tool is fetched here, and the command stays until it has landed,
printing each line the download or the package manager produces:

```
$ ed tools install yt-dlp

  EDITH · install yt-dlp
  ────────────────────────────────────────────────────
  · Downloading https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos
  · #####################                                                    29.4%
  · ######################################################################## 100.0%
  · Saved /Users/pulkit/Library/Application Support/Edith/bin/yt-dlp
  · 2026.07.04
  ✓ yt-dlp is ready

installed yt-dlp (2026.07.04)
```

Only the last line is on stdout. The header, the `·` rows and the `✓` are the
progress facility writing to stderr, and they are gone when stderr is not a
terminal or `--json` is passed. An install that cannot finish says why and what
to run instead:

```
$ ed tools install claude

  EDITH · install Claude Code
  ────────────────────────────────────────────────────
  · env: brew: No such file or directory
  · Homebrew was not found, checking npm.
  · env: npm: No such file or directory
  ✖ Neither Homebrew nor npm is available for installing Claude Code.
error: Neither Homebrew nor npm is available for installing Claude Code.
hint: Install with `brew install --cask claude-code` or `npm install -g @anthropic-ai/claude-code`.
```

An id that is not in the catalogue never reaches an install:

```
$ ed tools install ffmpeg
error: no tool called ffmpeg
hint: tools: yt-dlp, claude, codex
```

Behaviour: the presence check runs first, so an already-installed tool is
reported and exits 0 without touching the network. Only the other branch does
any work, and it does it here: `ToolInstaller` runs `curl`, `chmod` and a move
for yt-dlp, or `brew` and then `npm` for the two agent CLIs, in this process.
Nothing is posted at Edith and no part of it has to be running. Every line those
commands print is echoed as a `·` row as it arrives, which for the curl progress
bar is one row per redraw. When they finish, `ed` runs the tool's own
`--version` through the assembled PATH to prove it landed: a tool that cannot be
run there fails with `Installation finished, but <name> could not be verified.`
however well the install itself went. Any failure exits 4 with the reason as the
error and the tool's manual instruction as the hint, and writes nothing to
stdout, `--json` included.

## Where to go next

- [`ed tools`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
