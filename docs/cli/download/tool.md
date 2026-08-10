# `ed download tool`

Reports the yt-dlp that does the work, or runs its self-update.

Usage:

```
ed download tool [--update] [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--update` | flag | off | Runs `yt-dlp -U` on the copy that was found, rather than only reporting its version. |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments. yt-dlp is the one external program this
group depends on, and it is the only tool `ed download` manages. It is looked
up by scanning a fixed list of directories in order and taking the first
executable called `yt-dlp`:

```
~/Library/Application Support/Edith/bin    what Edith installs for you
~/.local/bin
~/.nvm/current/bin and each ~/.nvm/versions/node/*/bin, reverse alphabetical
/opt/homebrew/bin
/usr/local/bin
/usr/bin, /bin, /usr/sbin, /sbin
whatever your own PATH already contained, in its own order
```

Edith's own `bin` comes first, so a copy the app installed wins over a Homebrew
one. Directories under `/Volumes` that are not inside your home directory are
dropped from the search, so an unplugged external disk never decides the
answer. This is the same lookup the app uses, so `ed` and the Download sheet
always agree on which binary runs.

Installing is not here. `ed tools install yt-dlp` fetches `yt-dlp_macos` from
the official yt-dlp release itself, marks it executable and saves it into
`~/Library/Application Support/Edith/bin`, the same fetch the Music
extension's setup panel runs. It needs no app: it streams each step as it runs,
checks the binary answers `--version` afterwards, and fails with the manual
instruction when it did not land. `brew install yt-dlp` works just as well, and
`ed tools ls` reports which one PATH is offering.

`--json` shape without `--update`:

```json
{
  "installed": true,
  "path": "/Users/pulkit/Library/Application Support/Edith/bin/yt-dlp",
  "version": "2026.07.04"
}
```

`--json` shape with `--update`:

```json
{
  "after": "2026.08.02",
  "before": "2026.07.04",
  "changed": true,
  "path": "/Users/pulkit/Library/Application Support/Edith/bin/yt-dlp"
}
```

`path` and `version` are `null` when nothing was found, and `changed` compares
the version string before the update with the one after, so an update that had
nothing to do reports `false`.

Examples:

```
ed download tool
ed download tool --json
ed download tool --update
```

```
$ ed download tool
2026.07.04  /Users/pulkit/Library/Application Support/Edith/bin/yt-dlp

$ ed download tool --update
Updating to stable@2026.08.02 ... Updated yt-dlp to stable@2026.08.02
```

Behaviour: the two output modes disagree about what a missing yt-dlp means, on
purpose. The human path exits 4 with `yt-dlp is not installed` and a hint
naming both ways to get it, because a person typing this wants to be told. The
`--json` path reports `"installed": false` with two nulls and exits 0, because
an agent asking whether the tool is there should get an answer rather than an
error. `--update` draws no such distinction: with no yt-dlp to update it exits
4 in both modes, `--json` included. An update that runs and finds nothing newer
is not that case; it exits 0 and reports `"changed": false`.

Neither form needs Edith running: `ed` runs the binary itself. The version
string is whatever `yt-dlp --version` writes, on stdout or stderr, trimmed,
with no check on its exit status, so a copy that is present but broken reports
its complaint where a version would be. `--update` prints yt-dlp's own output
verbatim, and falls back to `yt-dlp is <version>` when the update was silent.
There is no `--yes` guard on `--update`, and a self-update run against a
Homebrew copy will say what Homebrew's yt-dlp says about being managed
elsewhere.

## Where to go next

- [`ed download`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
