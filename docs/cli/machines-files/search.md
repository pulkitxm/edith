# `ed machines files search`

Finds files by name under a directory. This is the window's search field.

```
ed machines files search <machine> <path> <query> [--limit <n>] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Which machine. |
| `path` | remote directory | required | Where to search, recursively. |
| `query` | text, matched anywhere in the file name | required | What to look for. |
| `--limit` | integer greater than zero | `300` | Stop after this many matches. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
[
  "/var/log/nginx/access.log",
  "/var/log/nginx/error.log",
  "/var/log/system.log"
]
```

```
ed machines files search studio /var/log nginx
ed machines files search studio /srv .env --limit 20
ed machines files search studio /Users/pulkit report --json
```

What runs is `find <path> -iname '*<query>*' -not -path '*/.git/*' | head`,
capped at 120 seconds. Matching is case-insensitive and against the name only,
never the contents, and `.git` directories are skipped so a search under a
source tree is not drowned in objects. Because the text goes to `-iname` as a
glob, a `*` or `?` inside it is honoured rather than escaped.

`find`'s own errors are discarded, which makes this quiet in a useful way and
misleading in one way: directories the account cannot read are skipped instead
of failing the command, and a directory that does not exist simply matches
nothing:

```
$ ed machines files search studio /var/log nothing-like-this
nothing under /var/log matches nothing-like-this
```

That note is on stderr and the exit code is 0. With `--json` the same case is an
empty array. Note that the document here is a top-level array of absolute paths,
not an object; it is the only command in this group shaped that way.

`--limit` is validated locally: zero or less exits 2 with
`--limit must be greater than zero`. Hitting the cap is silent, so a result of
exactly `--limit` lines means there may be more.

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
