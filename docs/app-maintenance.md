# App Maintenance

App Maintenance inventories regular apps in `/Applications` and `~/Applications`, shows installed versions, and adds available Homebrew cask updates when an exact app-name match is available. Enable it from Edith's Extensions pane, then open its maintenance window from the extension settings.

Select an app to build a removal plan. Edith always shows the application bundle and every support item before enabling removal. Only exact bundle-identifier paths in these user Library folders are eligible:

- Application Support
- Caches
- Preferences
- Containers
- Logs
- Saved Application State
- HTTPStorages and WebKit

Every row can be unchecked or revealed in Finder. Confirmed rows move to the macOS Trash, so they remain recoverable until the Trash is emptied. Apple apps, Edith itself, symlinked bundles, nested application paths, display-name guesses, and files that change after review are rejected.

No macOS permission is required to inventory apps or remove user-owned files. Administrator-owned apps may be listed but macOS can refuse to move them. App Maintenance reports those items as not moved and never falls back to permanent deletion.

The command line exposes the same inventory, scan, and removal plan:

```bash
ed maintenance inventory
ed maintenance scan /Applications/Example.app
ed maintenance remove /Applications/Example.app
ed maintenance remove /Applications/Example.app --yes
```

Removal is a preview unless `--yes` is present. Pass `--only-app` to leave every support item in place. Use `--json` for a stable machine-readable plan or result.
