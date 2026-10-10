# Remove

[CLI reference](../README.md) | [Extensions](./README.md)

Remove downloaded packages after stopping the extension.

```sh
ed extensions remove <id> [--json]
```

Preferences and user data are retained. Dependencies still required by another installed extension cannot be removed. Incompatible installed packages can be removed. A pending cleanup returns an error rather than claiming that removal completed.
