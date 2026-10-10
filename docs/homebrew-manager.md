# Homebrew Packages

The Packages section in App Maintenance provides a native, reviewable interface for formulae and casks. Enable App Maintenance in Edith's Extensions pane, verify the optional local Homebrew tool, then open App Maintenance from the main sidebar and choose Packages.

## Browse and discover packages

Installed shows the selected package kind with installed versions and available updates. Packages with an update are sorted first. Discover searches Homebrew metadata and shows up to 40 exact results with descriptions, versions, homepages, and installed state.

The Formulae and Casks control changes both the installed inventory and search domain. The selected kind is saved with App Maintenance settings. Refresh re-reads installed and outdated metadata without changing any package.

## Install, upgrade, and uninstall

Install and Upgrade always target one validated package token. Uninstall presents the exact package and kind in a confirmation dialog before Homebrew starts. Only one operation runs from the page at a time, and the active operation can be cancelled.

Edith invokes the local `brew` executable directly. It never downloads or executes a Homebrew installer. Every process runs noninteractively with automatic updates, analytics, and environment hints disabled. Reads are limited to 60 seconds and mutations to 30 minutes. Retained output is capped at 2 MB. Cancelling a mutation terminates its full process group.

Some casks need administrator authentication or interactive input. Edith reports that requirement and leaves the package unchanged instead of asking for a password. Run those exceptional operations directly in Terminal.

## Command line

Enable Homebrew and open its page to load the installed inventory. The active worker exposes the same cached inventory as a typed Home surface snapshot through `ed invoke homebrew surface.snapshot --json -`. Supply a complete `SurfaceSnapshotRequest` with target `home` and an `extension:homebrew` tile; the request follows the shared surface contract.

Package searches and mutations remain in the Homebrew and App Maintenance pages, with their confirmation and cancellation controls. The optional local `brew` tool remains available directly in Terminal. See the [public invocation reference](./cli/invoke/README.md) for the gateway's worker availability and JSON limits.
