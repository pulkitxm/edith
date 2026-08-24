# `ed app info`

Shows the identity of the installed Edith application.

```
ed app info [--json]
```

The plain form prints `name`, `version`, `build`, `bundle id`, and `bundle path`.
It reads the app beside the shipped CLI or `/Applications/Edith.app`, falling
back to the current bundle for a development build. It needs no running app.

`--json` emits one object with `name`, `version`, `build`, `bundleID`,
`bundlePath`, `repositoryURL`, and `creatorURL`. `bundleID` is `null` when the
development bundle has none.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
