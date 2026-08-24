# `ed app paths`

Lists the filesystem destinations that Edith exposes in its UI.

```
ed app paths [--json]
```

The ids are `app-data`, `icloud`, `data`, `refresh-log`, and `music`. Plain
output shows each id, whether it exists, and its absolute path. JSON is an array
whose rows have `id`, `label`, `path`, and `exists`.

The command only inspects the filesystem and needs no running app. Use the id
with [`ed app open-path`](./open-path.md).

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
