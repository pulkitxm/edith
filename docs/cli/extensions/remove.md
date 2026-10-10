# `ed extensions remove`

[CLI reference](../README.md) | [Extensions](./README.md)

Remove downloaded packages after stopping the extension.

```sh
ed extensions remove <id> [--json]
```

Preferences and user data are retained. Dependencies still required by another installed extension cannot be removed. Incompatible installed packages can be removed. If a running process holds the package, the result reports `removalPending: true` and `installed: true` until cleanup completes.
