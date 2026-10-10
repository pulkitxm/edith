# Update

[CLI reference](../README.md) | [Extensions](./README.md)

Check the signed catalog and install the current compatible release.

```sh
ed extensions update <id> [--json]
```

The extension must already be installed. A disabled extension remains disabled. An enabled extension switches workers using the same prepare, stop, verify, and rollback rules as the marketplace UI. A failed update retains the selected working version.
