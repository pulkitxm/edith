# `ed maintenance`

`ed maintenance` is the command-line surface for App Maintenance. It verifies and installs single-app disk images, inventories regular Applications folders, reports exact Homebrew update matches, previews exact bundle-identifier support files, and moves confirmed selections to the Trash.

[The `ed` command line](../README.md)

| Command | What it does |
| --- | --- |
| [`ed maintenance inventory`](./inventory.md) | Lists installed applications and optional Homebrew updates. |
| [`ed maintenance scan`](./scan.md) | Prints the application and exact support files Edith can review. |
| [`ed maintenance remove`](./remove.md) | Previews the removal selection, or moves it with `--yes`. |
| [`ed maintenance install`](./install.md) | Verifies and previews a single-app disk image, or installs it with `--yes`. |

Commands run locally and do not require Edith to be open. `inventory` and `scan` are read-only. `remove` changes nothing without `--yes`, and confirmed items always go to the Trash. `install` mounts the image read-only for its preview, verifies the app, and ejects it without installing unless `--yes` is present.

The App Maintenance extension settings explain the same supported paths and safety rules in the app.
