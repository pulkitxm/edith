# Ubuntu development

Edith targets Ubuntu 24.04 LTS with Swift 6.3.2 and GTK 4. Published Debian
packages currently target `amd64`. Local source builds also follow the architecture
of the installed Swift toolchain and Ubuntu system.

The Ubuntu application is an early native shell. It shares the extension catalog,
platform capability model, filesystem conventions, and portable tests with macOS.
Most macOS features still need Linux implementations before they can be marked
available or exposed in the GTK interface. Run `edith-linux --diagnose` to see the
current capability and extension status.

## Install the toolchain

Install Swiftly by following the official
[Swift on Linux guide](https://www.swift.org/install/linux/swiftly/), then select
the same Swift release used by CI:

```bash
swiftly install 6.3.2
swiftly use 6.3.2
swift --version
```

Swiftly installs into `~/.local/share/swiftly` and appends its `bin` directory to
your shell profile. The current shell does not pick that up until you run `hash -r`
or start a new one, so `swift --version` failing right after the install usually
means a stale shell rather than a failed install.

Swiftly also reports a set of packages its toolchain expects. They are not needed
to build `edith-linux`, but install them so the rest of the toolchain works:

```bash
sudo apt install --yes gnupg2 libcurl4-openssl-dev libncurses-dev libz3-dev
```

Install the native build and package dependencies:

```bash
sudo apt update
sudo apt install --yes \
  appstream \
  binutils \
  desktop-file-utils \
  dpkg-dev \
  git \
  libgtk-4-dev \
  make \
  pkg-config
```

`sudo apt update` exits non-zero when any configured third-party repository fails,
which silently skips the install in an `apt update && apt install` chain. Run the
two commands separately, or read the update output before trusting it.

Verify that SwiftPM can discover GTK 4:

```bash
pkg-config --modversion gtk4
```

Install [Bun](https://bun.sh/docs/installation) when running the repository policy
checks, then install the locked dependencies:

```bash
bun install --frozen-lockfile
```

## Build and run

From the repository root:

```bash
make linux-test
make linux-build
make linux-run
```

`make linux-run` requires a graphical desktop session. A shell that is not part of
one, such as a TTY, an SSH connection, or an editor's integrated terminal, has no
`WAYLAND_DISPLAY` or `DISPLAY`, and the process then exits silently with status 0
and no window rather than reporting the missing session. Point it at the running
session instead:

```bash
WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/$(id -u) make linux-run
```

`ls /run/user/$(id -u)` names the Wayland socket, and `ls /tmp/.X11-unix` names the
X displays, for a session that does not use `wayland-0`. On X11 pass `DISPLAY=:0`
in place of `WAYLAND_DISPLAY`.

The diagnostic path is headless and is useful over SSH or in CI:

```bash
make linux-diagnose
```

It prints the resolved XDG directories along with the extension and capability
state. Every extension currently reports `unavailable` on Ubuntu, and
`supportedCapabilities` is empty, because the Linux integrations described below
are not implemented yet. That output is the expected result of a working build,
not a broken installation.

Build the same release package produced by CI:

```bash
make linux-check
```

This tests the portable core, validates the desktop and AppStream metadata, and
creates `dist/linux/edith_<version>_<architecture>.deb`. Inspect and install it
with:

```bash
DEB_PATH="$(find dist/linux -maxdepth 1 -name 'edith_*.deb' -print -quit)"
dpkg-deb --info "$DEB_PATH"
dpkg-deb --contents "$DEB_PATH"
sudo apt install "$DEB_PATH"
edith-linux --diagnose
```

Remove an installed development package with `sudo apt remove edith`.

## Project layout

| Path | Responsibility |
| --- | --- |
| `Packages/Edith/Sources/EdithCore` | Portable models, extension declarations, capability contracts, and filesystem behavior. |
| `Packages/Edith/Sources/EdithLinux` | Linux process entry point and GTK application lifecycle. |
| `Packages/Edith/Sources/CGTK` | Minimal SwiftPM system-library bridge to GTK 4. |
| `packaging/linux` | Desktop entry, AppStream metadata, and application icon integration. |
| `packaging/debian` | Reproducible Debian staging and package construction. |
| `Packages/Edith/Tests/EdithCoreTests` | Tests that run on both macOS and Linux. |

User data follows the XDG base directory convention. The diagnostic output prints
the resolved configuration, data, cache, and runtime directories for the current
session.

## Adding or porting an extension

An extension has one shared declaration but separate native integrations when it
uses platform services. Adding a catalog entry makes both platforms aware of it.
It does not make a macOS implementation work on Ubuntu automatically.

1. Put portable state and domain behavior in `EdithCore` and cover it in
   `EdithCoreTests`.
2. Add the extension once in `ExtensionRegistry` with accurate required and
   optional `PlatformCapability` values.
3. Implement Ubuntu service adapters with GTK, freedesktop APIs, XDG portals,
   PipeWire, or the desktop integration appropriate to the capability.
4. Change the Ubuntu capability state to `available` or `permissionRequired` only
   after the integration works and has tests. Keep unfinished work as
   `integrationRequired` or `unsupported`.
5. Build the GTK presentation in `EdithLinux`. macOS presentation remains in the
   existing `Edith` and `EdithKit` targets.
6. Run `make linux-check`, `bun run check-comments`, and the relevant script tests
   before pushing.

Keep AppKit, SwiftUI, and other Apple-only APIs outside `EdithCore`. Keep GTK and
Linux-only APIs outside the macOS targets. Shared contracts and behavior should be
implemented once, while operating-system adapters and native presentation remain
platform-specific.

## Packaging rules

`packaging/debian/build-deb.sh` reads the application version from
`Resources/Info.plist` unless `VERSION` is supplied. It links the Swift runtime
statically, derives native shared-library dependencies with `dpkg-shlibdeps`,
strips the staged executable, and writes the package under `dist/linux`.

Do not hand-edit Debian control metadata after a build. Change the package script,
desktop entry, or AppStream metadata, then rebuild and inspect the resulting
archive. Release CI installs the generated package and runs its diagnostic command
before publication.
