# `ed maintenance install`

[`ed maintenance`](./README.md)

[The `ed` command line](../README.md)

```bash
ed maintenance install ~/Downloads/Example.dmg [--system] [--replace] [--keep-image] [--yes] [--json]
```

Mounts the disk image read-only and requires exactly one top-level application. The app bundle, executable, code signature, and Gatekeeper assessment must pass before Edith prints the reviewed destination. The preview ejects the image and installs nothing.

With `--yes`, Edith copies the app into a private staging directory, verifies the staged copy again, then moves it into `~/Applications`. Pass `--system` for `/Applications`. If the destination already contains the same bundle identifier, `--replace` is also required and the old app moves to the Trash. A destination with a different bundle identifier is rejected.

After a successful install, Edith ejects the image before moving the original `.dmg` to the Trash. `--keep-image` preserves it. Failed ejection also preserves it. Edith rechecks reviewed file identities before every move and does not permanently delete an app or disk image.

JSON previews include `applied: false`, verified app metadata, the destination, replacement state, and disk image size. Applied results report the installed path, replacement state, ejection state, and disk image cleanup state.
