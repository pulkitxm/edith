# `ed machines forwards open`

Opens the local side of a saved port forward in the default browser.

```
ed machines forwards open <machine> <index> [--json]
```

The index is the forward's position in `ed machines forwards ls`. The URL is
always `http://localhost:<localPort>`. This does not turn the forward on, so use
`ed machines forwards on` first when it is closed.

`--json` performs the open and reports `index`, `machine`, `opened` and `url`.
An unknown index exits 3, and a browser launch failure exits 4.

```
ed machines forwards on tuf 1
ed machines forwards open tuf 1 --json
```

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
