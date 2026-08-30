# App Maintenance

App Maintenance combines an App Update Center, verified single-app disk image installation, and review-first removal. Enable it from Edith's Extensions pane, then open its maintenance window from the extension settings.

## Review application updates

The Updates section checks installed apps through Homebrew casks and formulae, Mac App Store metadata through `mas` when it is installed, and HTTPS Sparkle or standard app feed URLs declared by the app bundle. Findings show the source, current and available versions, release information when supplied, confidence, check time, and exact action.

Select any combination to build a batch plan. Edith shows the command before running it, requires confirmation, limits concurrent work to the configured bound, retries failures, records a result for every item, and supports cancellation. Managed sources run their native command. Feed-based apps open so their own updater remains in control. You can reveal an app, copy its command, ignore one version, snooze it for a day, or exclude the app. Hidden policies can be reset from update settings.

Automatic refresh is off by default and only performs discovery when enabled. It never installs an update. Optional notifications only follow an automatic refresh. If Edith Automations is installed and enabled, the settings popover exposes `ed maintenance updates --json` as the safe scheduling hook. Closing App Maintenance cancels active discovery and update work.

Update policy and per-item history are stored in `~/Library/Application Support/Edith/app-update-center.json`. Settings participate in Edith's settings backup. Use `ed maintenance backup-updates <path>` to make an explicit portable copy of policy and history.

## Install from a disk image

Choose **Install Disk Image** and select a `.dmg`. Edith mounts it read-only and accepts exactly one regular top-level application. It validates the bundle and executable, rejects Apple apps and Edith, verifies the deep code signature, and requires an accepted Gatekeeper assessment when assessments are enabled.

The review sheet shows the verified app, version, bundle identifier, disk image, destination, and any existing app that would be replaced. Installation is explicit. The app is copied into a private staging directory and verified a second time before it moves into Applications. An existing app can only be replaced when its bundle identifier matches, the replacement toggle is selected, and its reviewed identity has not changed. The old app goes to the Trash.

After installation, Edith ejects the mounted image. The downloaded `.dmg` only moves to the Trash after a successful eject and a final identity check. You can keep the image from the review sheet. Failed ejection or changed input leaves the image in place.

## Remove an application

Select an app to build a removal plan. Edith always shows the application bundle and every support item before enabling removal. Only exact bundle-identifier paths in these user Library folders are eligible:

- Application Support
- Caches
- Preferences
- Containers
- Logs
- Saved Application State
- HTTPStorages and WebKit

Every row can be unchecked or revealed in Finder. Confirmed rows move to the macOS Trash, so they remain recoverable until the Trash is emptied. Apple apps, Edith itself, symlinked bundles, nested application paths, display-name guesses, and files that change after review are rejected.

No macOS permission is required to inventory apps, install into `~/Applications`, or remove user-owned files. Installing into `/Applications`, replacing administrator-owned apps, or removing administrator-owned files can be refused by macOS. App Maintenance reports the failure and never falls back to permanent deletion or privilege escalation.

The command line exposes the same installer, inventory, scan, and removal plans:

```bash
ed maintenance inventory
ed maintenance updates
ed maintenance update
ed maintenance update --yes
ed maintenance history --json
ed maintenance backup-updates ~/Desktop/edith-updates.json
ed maintenance install ~/Downloads/Example.dmg
ed maintenance install ~/Downloads/Example.dmg --yes
ed maintenance scan /Applications/Example.app
ed maintenance remove /Applications/Example.app
ed maintenance remove /Applications/Example.app --yes
```

Updates, installation, and removal are previews unless `--yes` is present. Installer previews eject the image without installing. Pass `--system` to target `/Applications`, `--replace` to confirm a reviewed replacement, or `--keep-image` to preserve the download. Pass `--only-app` during removal to leave every support item in place. Use `--json` for a stable machine-readable plan or result.
