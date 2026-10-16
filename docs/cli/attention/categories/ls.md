# `ed attention categories ls`

Lists the editable category taxonomy and every identity rule.

```
ed attention categories ls [--json]
```

The JSON object has `categories` and `rules` arrays. Categories expose `id`,
`name`, `kind`, and `color`. Rules expose their identity `id`, display `name`,
`categoryID`, `bundleIDs`, and `domains`. `list` is an alias for `ls`.

## Where to go next

- [`ed attention`](../README.md)
- [`ed attention categories set`](./set.md)
