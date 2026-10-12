# `ed extensions disable`

[CLI reference](../README.md) | [Extensions](./README.md)

Stop an extension and clear its remembered enabled setting.

```sh
ed extensions disable <id> [--json]
```

Disable waits for owned operations and cleanup. If the extension requires recovery or an external approval, the command returns the same actionable error as the marketplace UI. A completed disable leaves no worker for the extension.
