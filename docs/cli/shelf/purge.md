# `ed shelf purge`

Previews and removes shelf items older than an expiry window.

```text
ed shelf purge [forever|oneHour|oneDay|oneWeek|oneMonth] [--yes] [--json]
```

Without a window, the command reads `notchShelfKeepDuration` and falls back to
`forever`. Without `--yes`, it prints the exact file paths it would remove and
does not change the files or index. Add `--yes` to apply the same expiry
executor used by the running notch shelf.

```sh
ed shelf purge oneWeek
ed shelf purge oneWeek --yes
ed shelf purge oneDay --json
```

JSON preview output includes `action`, `targets`, `keep`, `removed`, `applied`
and `changed`. Applied output also includes `remaining`. An unknown window exits
2, and a filesystem or index failure exits 1.

## Where to go next

- [`ed shelf`](./README.md)
- [`ed config`](../config/README.md)
- [All `ed` commands](../README.md)
