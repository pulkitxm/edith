# `ed maintenance remove`

[`ed maintenance`](./README.md)

[The `ed` command line](../README.md)

```bash
ed maintenance remove /Applications/Example.app [--only-app] [--yes] [--json]
```

Without `--yes`, prints the exact selection and changes nothing. With `--yes`, revalidates the app and every selected file, then moves each item to the Trash. `--only-app` selects only the application bundle and leaves support files in place.

JSON previews include `applied: false`, the complete reviewed item list, and the selected item list. Applied results include the removed and failed items plus reclaimed bytes. A failed item remains in place.
