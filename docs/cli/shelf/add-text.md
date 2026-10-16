# `ed shelf add-text`

Writes text into a new `Dropped Text.txt` shelf item, using a numbered name when
that file already exists.

```text
ed shelf add-text <text...> [--json]
```

Words are joined with spaces. Quote shell metacharacters or newlines when they
must reach the item unchanged. The command and a text drop in the notch use the
same shelf mutation executor, persist the same index shape, and notify a running
shelf after the write succeeds.

JSON output is the same item document returned by `ed shelf add --json`, with
`index`, `id`, `name`, `path`, `sizeBytes`, `addedAt`, `exists` and a null
`position`. Its index comes from the committed shelf snapshot and matches the
next `ed shelf ls --json` result.

```sh
ed shelf add-text remember to publish
ed shelf add-text $'first line\nsecond line' --json
```

Missing text exits 2. A filesystem or index write failure exits 1 without
claiming success.

## Where to go next

- [`ed shelf`](./README.md)
- [All `ed` commands](../README.md)
