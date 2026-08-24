# `ed app links`

Lists the external links already shown by Edith.

```
ed app links [--json]
```

The fixed ids are `repository` and `creator`. Extension lifecycle guides add
ids in the form `extension-doc:<extension>:<document>`, and cached contributors
add `contributor:<login>`. Plain output shows id, label, and URL. JSON is an
array whose rows have `id`, `label`, and `url`.

This read needs no running app and does not fetch contributor data. Use an id
with [`ed app open-link`](./open-link.md).

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
