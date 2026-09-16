# `ed bifrost reindex`

Asks the running menu bar app to scan the application folders again and replace
the cached index.

Usage:

```
ed bifrost reindex [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments. The plain response is one line:

```
index rebuild requested
```

The JSON response has two stable fields:

```json
{
  "operation": "bifrost.reindex",
  "requested": true
}
```

`requested` means the fire-and-forget request was sent. The command exits there:
it does not wait for the scan and does not report how many applications were
found. Read that afterwards with [`ed bifrost ls --json`](./ls.md), or from the
Bifrost settings pane, which states the count.

The scan walks `/Applications`, `/System/Applications`,
`/System/Library/CoreServices/Applications`,
`/System/Cryptexes/App/System/Applications` and `~/Applications`, three
directory levels deep, and never descends into a bundle. It runs off the main
thread in the menu bar app, so the bar stays responsive while it happens, and
the result is written to `~/Library/Caches/Edith/bifrost-index.json`.

Reach for it after installing something the bar has not noticed. You should not
need it otherwise: the bar builds the index the first time it runs with no cache
at all.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | The rebuild was requested. |
| 2 | The command line was invalid. |
| 4 | The Bifrost extension is off, or Edith's menu bar app is not running. |

The extension is checked first, before the app:

```
ed extensions enable bifrost
ed bifrost reindex
```

The command never starts Edith by itself and never changes the extension
setting. The cache it replaces is a cache: deleting the file loses nothing but
the next scan.

## Where to go next

- [`ed bifrost ls`](./ls.md), to read what the scan found
- [`ed bifrost`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
