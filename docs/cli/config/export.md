# `ed config export`

Prints the settings you have changed as one JSON document, ready for
`ed config import` on another Mac.

```
ed config export [--defaults] > edith.json
```

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--defaults` | flag | `false` | Include settings still at their default |

This is the one command in the group with no `--json`, because all of its output
is JSON already; passing the flag exits 2. The document is an object of key to
current value, keys sorted, which is exactly the shape `ed schema` describes.

```json
{
  "budgetCapPercent": 90,
  "clipboardEnabled": true,
  "clipboardMaxItems": 500,
  "limitsProvider": "claude",
  "presenterEnabled": true,
  "preventSleep": true,
  "tabMachinesEnabled": true,
  "tabUsageEnabled": true
}
```

```
ed config export > edith.json
ed config export --defaults > everything.json
ed config export | jq 'keys | length'
```

Read-only keys and the two `map` settings are never exported, with or without
`--defaults`, because neither can be imported: that leaves 177 exportable keys
of the 201. Without `--defaults` you get only the ones carrying a value of their
own, which is a much shorter list and is the one worth moving between Macs.

## Where to go next

- [`ed config`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
