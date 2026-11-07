# `ed extensions update`

[CLI reference](../README.md) | [Extensions](./README.md)

Check the signed catalog and install the current compatible release.

```sh
ed extensions update <id> [--json]
ed extensions update --all [--json]
```

The extension must already be installed. A disabled extension remains disabled. An enabled extension switches workers using the same prepare, stop, verify, and rollback rules as the marketplace UI. A failed update retains the selected working version.

When the running version has already loaded a native library that the update replaces, the library cannot be swapped inside the running app. The update is downloaded and kept, the current version keeps running, and the result reports `restartRequired: true` with `pendingVersion`. The new version starts the next time Edith launches.

The command allows up to 30 minutes for downloading and verification. Disconnecting or cancelling the command cancels its owned work.

`--all` refreshes the catalog and updates every installed extension that has an update, continuing past failures. It prints `{"updated":[...],"restartRequired":[...],"failed":{"id":"reason"},"upToDate":[...]}`, where `restartRequired` lists updates that finish when Edith restarts.
