# `ed machines files get-many`

Downloads several files from one machine into a local directory.

```
ed machines files get-many <machine> <paths>... [--to <directory>] [--dry-run] [--replace] [--yes] [--json]
```

The destination defaults to the working directory. Existing names are kept by
adding a number, so `report.txt` becomes `report 2.txt`. The destination
directory must already exist. Duplicate names in one request are numbered in
input order.

```
ed machines files get-many tuf /etc/hosts /etc/services --to ~/Desktop
ed machines files get-many tuf /srv/a.txt /srv/b.txt --to ./out --dry-run
```

`--dry-run` resolves every destination and moves no bytes. `--replace` shows
which existing files would be replaced, but it still does nothing until
`--yes` is also present. JSON always reports `items`, `skipped`, `executed`,
`dryRun` and `requiresConfirmation`. An executed response adds `completed` and
`failures`. Every failure includes both its source and resolved destination, so
duplicate input names remain unambiguous.

Each source must be a file. A failure for one item does not stop later items,
and the command exits 1 after reporting every failure.

## Where to go next

- [`ed machines files transfer`](./transfer.md), copy files between machines
- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
