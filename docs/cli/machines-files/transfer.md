# `ed machines files transfer`

Copies several files from one configured machine to another.

```
ed machines files transfer <source> <destination> <paths>... --into <directory> [--dry-run] [--replace] [--yes] [--json]
```

Both connections are opened concurrently. Files are staged on this Mac, then
uploaded to a temporary destination name and moved into place. Input order is
preserved in plans, progress, JSON and failure reporting.

```
ed machines files transfer tuf server /srv/a.txt /srv/b.txt --into /archive
ed machines files transfer tuf server /srv/report.txt --into /archive --dry-run
```

Existing names use keep-both numbering by default. `--replace` previews
replacement and requires `--yes` before any transfer begins. `--dry-run` lists
the exact resolved targets without moving bytes. Source and destination must be
different machines.

Each source must be a file. A failed item does not stop later items, and any
failure makes the final exit status 1. Each structured failure repeats the
resolved destination from the plan.

## Where to go next

- [`ed machines files get-many`](./get-many.md), download a selection to this Mac
- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
