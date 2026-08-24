# `ed shelf update`

Sets one shelf item's stored notch canvas position through the shared mutation
executor used by native dragging.

```text
ed shelf update <n> --x <number> --y <number> [--json]
```

The item number comes from `ed shelf ls`. Both coordinates are required and may
be integers or decimals. The canvas can clamp or reinterpret coordinates when
its available size changes, so use this command to reproduce a stored position,
not to target a universal screen point.

```sh
ed shelf update 1 --x 120 --y 60
ed shelf update 2 --x 84.5 --y 42 --json
```

JSON reports `action`, `changed`, and the complete updated `item`, including its
`position`. Repeating the same coordinates succeeds with `changed: false`. An
unknown item exits 3, and an empty shelf exits 4.

## Where to go next

- [`ed shelf`](./README.md)
- [`ed shelf ls`](./ls.md)
- [All `ed` commands](../README.md)
