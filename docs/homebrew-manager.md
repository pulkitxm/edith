# Homebrew Packages

The Packages section in App Maintenance provides a native, reviewable interface for formulae and casks. Enable App Maintenance in Edith's Extensions pane, verify the optional local Homebrew tool, then open App Maintenance and choose Packages.

## Browse and discover packages

Installed shows the selected package kind with installed versions and available updates. Packages with an update are sorted first. Discover searches Homebrew metadata and shows up to 40 exact results with descriptions, versions, homepages, and installed state.

The Formulae and Casks control changes both the installed inventory and search domain. The selected kind is saved with App Maintenance settings. Refresh re-reads installed and outdated metadata without changing any package.

## Install, upgrade, and uninstall

Install and Upgrade always target one validated package token. Uninstall presents the exact package and kind in a confirmation dialog before Homebrew starts. Only one operation runs from the page at a time, and the active operation can be cancelled.

Edith invokes the local `brew` executable directly. It never downloads or executes a Homebrew installer. Every process runs noninteractively with automatic updates, analytics, and environment hints disabled. Reads are limited to 60 seconds and mutations to 30 minutes. Retained output is capped at 2 MB. Cancelling a mutation terminates its full process group.

Some casks need administrator authentication or interactive input. Edith reports that requirement and leaves the package unchanged instead of asking for a password. Run those exceptional operations directly in Terminal.

## Command line

The command line uses the same validation, parsing, process limits, and package models:

```bash
ed brew status --json
ed brew ls --kind formula --outdated --json
ed brew search firefox --kind cask --json
ed brew install ripgrep --kind formula
ed brew upgrade ripgrep --kind formula
ed brew uninstall ripgrep --kind formula
ed brew uninstall ripgrep --kind formula --yes
```

Uninstall is a preview unless `--yes` is present. Reporting and mutation commands support stable JSON output. See the complete [`ed brew` reference](./cli/brew/README.md) for fields, defaults, and aliases.
