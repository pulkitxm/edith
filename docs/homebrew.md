# Homebrew

For how Homebrew itself works, what taps and casks are, and why this pipeline is
shaped the way it is, see [homebrew-internals.md](homebrew-internals.md). This page
is the command reference.

`Casks/edith.rb` is authored in this repository, next to the source it installs. The
release workflow rewrites its version and checksum from the disk image it just
published, then mirrors the file to
[pulkitxm/homebrew-tap](https://github.com/pulkitxm/homebrew-tap), the tap
Homebrew actually clones. That repository is generated output; never edit it by hand.

## Install

```
brew install --cask pulkitxm/tap/edith
```

There is no separate tap step. `brew install` resolves the fully qualified
`user/repository/token` form and taps `pulkitxm/homebrew-tap` for you before it
installs. The tap exists as its own repository because Homebrew only accepts the
short `brew tap pulkitxm/edith` form for repositories named `homebrew-<name>`, and
because cloning a few kilobytes of cask beats cloning this repository.

The cask installs `Edith.app` into `/Applications` and links the two command line
tools that ship inside the bundle:

```
ed      the full CLI, everything the UI can do
edh     the same binary under its short name
```

Both land in Homebrew's `bin` directory, which sits ahead of `/usr/bin` on the
default `PATH`. `ed` therefore shadows the POSIX line editor of the same name; run
`/usr/bin/ed` when you want that one. Nothing is copied into `~/.local/bin`, so
`ed install` is only needed when Edith was not installed through Homebrew.

Requirements are declared in the cask and enforced by Homebrew: macOS 14 or later
on Apple Silicon.

## Update

Edith updates itself through Sparkle, so the cask is marked `auto_updates true` and
a routine `brew upgrade` leaves it alone rather than fighting the in-app updater.
Refresh the tap and force Homebrew to reinstall the newest release with:

```
brew update
brew upgrade --cask --greedy edith
```

`brew update` alone only refreshes the tap; it changes nothing on disk. To reinstall
the version the cask currently names, without waiting for a new release:

```
brew reinstall --cask edith
```

## Inspect

```
brew info --cask edith          version, checksum, what the cask installs
brew list --cask edith          the paths Homebrew put on disk
brew outdated --cask --greedy   whether a newer release exists
```

## Uninstall

```
brew uninstall --cask edith
```

That removes the app and the two symlinks, quitting Edith, its menu bar helper and
the Files helper first. To also delete settings, caches and usage history:

```
brew uninstall --cask --zap edith
```

Stop tracking the tap entirely with:

```
brew untap pulkitxm/tap
```

## Releasing

Nothing about the cask is hand-edited. The `cask` job in
`.github/workflows/release.yml` runs after the release is published, hashes the
`Edith.dmg` it built, rewrites the `version` and `sha256` lines, commits the result
to `main`, and pushes the same file to the tap repository. That commit touches only
`Casks/`, which is outside the paths that trigger a release, so it cannot loop.

Pushing to the tap needs a `TAP_PUSH_TOKEN` secret on this repository: a fine
grained personal access token scoped to `pulkitxm/homebrew-tap` with read and
write access to contents. Without it the job fails loudly rather than releasing a
version the tap does not know about.
