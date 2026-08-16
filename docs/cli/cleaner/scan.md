# `ed cleaner scan`

Measures what could be reclaimed, and changes nothing. This is the default
subcommand, so `ed cleaner` with nothing after it is `ed cleaner scan`.

Usage:

```
ed cleaner scan [--category <c>] [--root <dir>]... [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--category <c>` | one of the nineteen ids listed above, matched exactly | unset, which means every category | Restricts the report to that one category. |
| `--root <dir>` | a path to an existing directory, repeatable | none | Also sweeps this folder for project junk. Repeat the flag for more than one folder. |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments. Completion offers the eleven fixed category
ids in the first positional slot anyway, because the completion tree hangs them
off the command rather than off `--category`; typing one is an ArgumentParser
error and exits 2.

`--root` expands a leading `~` itself, so a quoted `--root '~/code'` works even
when the shell did not expand it, and a relative path is resolved against the
current directory. The path has to exist and has to be a directory; anything
else exits 3 with `there is no folder at <path>`.

`--json` shape:

```json
{
  "categories": [
    {
      "category": "npm",
      "detail": "Tarball cache, re-downloaded on install.",
      "items": [
        {
          "name": "content-v2",
          "path": "/Users/pulkit/.npm/_cacache/content-v2",
          "sizeBytes": 2258612224
        },
        {
          "name": "index-v5",
          "path": "/Users/pulkit/.npm/_cacache/index-v5",
          "sizeBytes": 14942208
        }
      ],
      "name": "npm cache",
      "sizeBytes": 2273554432
    }
  ],
  "totalBytes": 2273554432
}
```

`category` is the id, `name` and `detail` are the human strings the Cleaner
card shows on the row, and `sizeBytes` on a category is the sum of its items.
`totalBytes` is the sum across categories. An item's `name` is not the same
kind of thing in both families: for a fixed cache it is the last path
component, and for project junk it is the full path with your home directory
abbreviated to `~`. `path` is always absolute and is what would be trashed.

Examples:

```
ed cleaner scan
ed cleaner scan --category derivedData
ed cleaner scan --root ~/code --root ~/work
ed cleaner scan --root ~/code --category nodeModules --json
```

A full scan of the fixed caches plus one swept folder:

```
$ ed cleaner scan --root ~/code
ID           SIZE     ITEMS  NAME
derivedData  41.0 KB  2      Xcode DerivedData
swiftpm      82.5 MB  3      Swift Package cache
npm          2.3 GB   2      npm cache
bun          5.5 GB   2232   Bun cache
pip          41.0 KB  2      pip cache
homebrew     1.1 GB   3      Homebrew cache
playwright   1.7 GB   7      Playwright browsers
claudeMcp    15.9 MB  40     Claude Code MCP logs
rustTarget   1.2 MB   1      Cargo / Maven target
nodeModules  922 KB   1      node_modules
pyvenv       512 KB   1      Python virtualenvs
nextBuild    307 KB   1      Next.js .next
pycache      41.0 KB  1      Python __pycache__

total 10.6 GB
```

The fixed caches come first, in catalogue order, and only the ones that exist
on this Mac appear: `yarn`, `puppeteer` and `claudeCode` are absent above
because those paths are not there. The project categories follow, sorted
largest first.

Naming a project category without a folder to sweep says so rather than
pretending the id is unknown, and exits 1:

```
$ ed cleaner scan --category nodeModules
error: nodeModules only turns up when a folder is swept for project junk
hint: pass --root, for example `ed cleaner scan --root ~/code --category nodeModules`
```

An id that is not one of the nineteen exits 3 and lists all of them:

```
$ ed cleaner scan --category bogus
error: no cleaner category named bogus
hint: categories: derivedData, swiftpm, npm, yarn, bun, pip, homebrew, playwright, puppeteer, claudeCode, claudeMcp, nodeModules, pycache, pyvenv, rustTarget, gradle, pods, nextBuild, turbo
```

Behaviour: `scan` reads the filesystem and changes nothing on it. It needs
neither the main app nor the menu bar helper, and it does not read or write the
Cleaner card's saved selection. A scan that finds nothing writes
`nothing to reclaim` to stderr, leaves stdout empty and exits 0; with `--json`
it prints the usual document on stdout with an empty `categories` array and a
`totalBytes` of 0 instead. Sizes are on-disk allocated size, summed over regular
files only, so directories and symlinks contribute nothing and the number can
differ from what `ls -l` implies.

While it walks it says what it is walking. A single spinner line on stderr
starts as `scanning` and then names each fixed cache as the scan reaches it, by
display name rather than id, so `Xcode DerivedData`, then `Swift Package cache`,
then `npm cache`; the swept folders follow as
`Scanning <folder> for project junk…`, one per `--root`. The line is rewritten
in place, carries the seconds elapsed since the scan began, and is erased before
the table lands, so it leaves nothing in the transcript. It never touches
stdout: the table and the `--json` document are the same either way.

## Where to go next

- [`ed cleaner`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
