# `ed maintenance`

`ed maintenance` is the command-line surface for App Maintenance. It discovers updates across supported sources, runs reviewed batches, verifies and installs single-app disk images, previews exact bundle-identifier support files, and moves confirmed selections to the Trash.

[The `ed` command line](../README.md)

| Command | What it does |
| --- | --- |
| [`ed maintenance inventory`](./inventory.md) | Lists installed applications and optional Homebrew updates. |
| [`ed maintenance scan`](./scan.md) | Prints the application and exact support files Edith can review. |
| [`ed maintenance remove`](./remove.md) | Previews the removal selection, or moves it with `--yes`. |
| [`ed maintenance install`](./install.md) | Verifies and previews a single-app disk image, or installs it with `--yes`. |
| [`ed maintenance updates`](./updates.md) | Discovers the unified update inventory. |
| [`ed maintenance update`](./update.md) | Previews a selected update batch, or runs it with `--yes`. |
| [`ed maintenance history`](./history.md) | Shows persisted per-item update results. |
| [`ed maintenance backup-updates`](./backup-updates.md) | Copies update policy and history to a new file. |

Commands run locally and do not require Edith to be open. `inventory`, `updates`, `history`, and `scan` are read-only. `update`, `remove`, and `install` require `--yes` before applying their reviewed plan.

The App Maintenance extension settings explain the same supported paths and safety rules in the app.
