# `ed cleaner categories`

Lists the fixed caches the cleaner knows how to reclaim, one row per id, with
the one-line description of what that cache holds. The home-relative paths each
id covers are in the `--json` output only; the table does not have a column for
them. `ed cleaner ls` is an alias.

Usage:

```
ed cleaner categories [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments and no filters: this prints the whole
catalogue every time.

`--json` shape, an array with one object per category, in catalogue order:

```json
[
  {
    "category": "derivedData",
    "detail": "Build intermediates, rebuilt on next build.",
    "name": "Xcode DerivedData",
    "onByDefault": true,
    "paths": [
      "Library/Developer/Xcode/DerivedData"
    ]
  },
  {
    "category": "playwright",
    "detail": "Re-downloaded on next test run.",
    "name": "Playwright browsers",
    "onByDefault": false,
    "paths": [
      "Library/Caches/ms-playwright"
    ]
  },
  {
    "category": "claudeCode",
    "detail": "Debug logs and shell snapshots. Transcripts are left untouched.",
    "name": "Claude Code logs",
    "onByDefault": true,
    "paths": [
      ".claude/debug",
      ".claude/shell-snapshots"
    ]
  }
]
```

`paths` are relative to your home directory, never absolute, and a category can
name more than one, as `claudeCode` does. They are printed whether or not they
exist here, which is the difference between this command and `scan`.
`onByDefault` is the Cleaner card's initial checkbox for that row and has no
effect on the CLI.

Examples:

```
ed cleaner categories
ed cleaner ls
ed cleaner categories --json
```

```
$ ed cleaner categories
ID           NAME                           WHAT
derivedData  Xcode DerivedData     default  Build intermediates, rebuilt on next build.
swiftpm      Swift Package cache   default  Cached package checkouts, re-fetched on demand.
npm          npm cache             default  Tarball cache, re-downloaded on install.
yarn         Yarn cache            default  Re-downloaded on install.
bun          Bun cache             default  Re-downloaded on install.
pip          pip cache             default  Wheel cache, re-downloaded on install.
homebrew     Homebrew cache        default  Downloaded bottles.
playwright   Playwright browsers            Re-downloaded on next test run.
puppeteer    Puppeteer cache                Re-downloaded on next run.
claudeCode   Claude Code logs      default  Debug logs and shell snapshots. Transcripts are left untouched.
claudeMcp    Claude Code MCP logs  default  MCP server logs that can grow very large.
```

The third column has no header; a row carries `default` there when that
category is ticked in the card to begin with, and is blank otherwise.

Behaviour: this is a constant table compiled into the binary. It touches no
files, cannot fail, and needs nothing running. It never lists the eight project
categories, even though `--category` accepts them and the not-found hint from
`scan` and `clean` names them, so this is not the complete list of ids.

## Where to go next

- [`ed cleaner`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
