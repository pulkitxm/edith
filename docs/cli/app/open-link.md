# `ed app open-link`

Opens one URL from [`ed app links`](./links.md).

```
ed app open-link <repository|creator|contributor:login> [--json]
```

The command resolves the id before asking macOS to open it, so it never accepts
an arbitrary URL. Plain output prints the exact URL. JSON has `id`, `url`,
`mode`, and `opened`; successful link opens use mode `open`.

An unknown id exits 3 and points back to `ed app links`. A macOS open failure
exits 4. No Edith process is required.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
