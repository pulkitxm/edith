# <img src="apps/macos/Sources/Edith/Resources/appicon.png" width="30" align="top" alt=""> Edith

A native SwiftUI menu bar app for the Mac - a dark, minimal personal control
center built to run 24/7 on near-zero resources.

## Features

- **Rate-limit rings** - session (5h) and weekly usage as live animated gauges with second-by-second countdowns and a 24h history spark.
- **Menu-bar limits** - optional second menu bar readout of session + weekly %, tinted by a time-aware risk model.
- **Smart notifications** - threshold, ahead-of-pace, burning-hot, back-to-green and pre-reset alerts, all optional, with a self-diagnosing test button.
- **Activity heatmap** - GitHub-style daily spend calendar across your full history.
- **Token & cost stats** - today / week / billing cycle, filterable by agent (Claude Code, Codex, OpenCode…).
- **Full dashboard** - a native window with KPIs, per-day / model / source / project / hourly charts, a sortable model table and an activity heatmap, all interactive; refreshed by a self-contained collector bundled in the app.
- **Notch shelf** - the notch becomes a hover-to-open shelf with drag-and-drop file staging, now-playing controls, a camera check tab and morphing inline alerts.
- **Clipboard history** - a global paste panel with search and synthesized paste-in-place.
- **Color picker** - system-wide eyedropper on a global hotkey, with swatch history.
- **Music player** - plays your local music folder with thumbnails, drag-to-seek, fades, auto-advance and media keys; also picks up Spotify / Apple Music playback.
- **Audio mixer** - per-app volume control.
- **Mic mute** - system-wide microphone kill switch with hotkey and menu bar indicator.
- **Focus dim** - dims every screen except the window you are working in.
- **Calendar** - EventKit agenda grouped by day, blur-aware in presenter mode.
- **System tools** - prevent-sleep toggle, system stats readout and a keyboard-cleaning lock with a 60s auto-restore.
- **Presenter mode** - blurs track names, calendar entries and spend figures for screen sharing, with automatic screen-share detection.
- **Global shortcut** - toggle the panel from anywhere (default ⌥⌘E), re-recordable.
- **Local-first** - usage data never leaves your Mac; optional iCloud backup that merges across machines.

## Benchmarks

Built to idle cheaply. Measured on an Apple M4 Pro - CPU as a share of one core
(the convention Activity Monitor uses), memory as physical footprint:

| State | CPU | Memory |
| --- | --- | --- |
| Idle, panel closed | ~0% | ~22 MB |
| Music playing, panel closed | ~1% | ~40 MB |
| Music playing, panel open (visualizer on screen) | ~29% | ~42 MB |
| Paused | <1% | ~40 MB |

Numbers from the 2026-07 optimization pass (`ps -o %cpu,rss,cputime` sampled
once per second for 180s per state, comparing cputime deltas):

| Metric | Before | After |
| --- | --- | --- |
| Menu bar process, idle | 2.22% CPU / 121 MB | ~0.0% CPU / 89 MB |
| Main window process, idle | 0.23% CPU / 131 MB | ~0.0% CPU / 108 MB |
| Music playing (window visible) | 20-40% CPU | 0.7-1.6% CPU |
| Music paused or window hidden | up to 17% CPU | 0.0% CPU |
| Usage collector walk phase | ~75s per 5-min run | incremental cache, sub-second when unchanged |

How it stays there: disabling a tab tears down its timers, observers and
background jobs entirely; per-frame UI (the music visualizer and scrubber) only
redraws while the panel is open and playing; and the usage collector caches
per-transcript parses so a refresh only touches files that changed.

## Build & install

```bash
cd apps/macos
./build.sh            # build + run from dist/
./build.sh --install  # build + copy to /Applications + launch
./test.sh             # run the Swift test suite
```

Needs only Xcode Command Line Tools (Swift 6).

`build.sh` also assembles a small `Edith.app` login item nested inside the main
`Edith.app` (`Contents/Library/LoginItems`) - the always-on menu bar
companion that will keep running after the main app quits. Both bundles are
signed ad-hoc by default. Ad-hoc signatures change on every rebuild, which
resets TCC permission grants (Accessibility, Screen Recording, ...) and can
duplicate login-item registrations. To avoid that, create a self-signed
code-signing certificate once - Keychain Access → menu bar → Certificate
Assistant → Create a Certificate…, name it "Edith Dev", Identity Type
"Self Signed Root", Certificate Type "Code Signing" - then build with:

```bash
EDITH_SIGN_IDENTITY="Edith Dev" ./build.sh --install
```

## Makefile commands

<details>
<summary>All <code>make</code> targets, explained</summary>

### CI

| Target | What it does |
| --- | --- |
| `make ci` | Full local CI: `bun install --frozen-lockfile`, then comments, secrets, lint, script tests, web, promo-video and Swift checks. |
| `make ci-comments` | Self-tests the comment stripper, then fails on any disallowed comment in tracked source. |
| `make ci-secrets` | Scans every tracked file for leaked secrets. |
| `make ci-lint` | Biome format + lint for the JS/TS surface. |
| `make ci-scripts` | Runs the `bun test` suite for `scripts/`. |
| `make ci-web` | Runs the web app tests and a `tsc --noEmit` type check in `apps/web`. |
| `make ci-promo` | `npm ci` + type check for the Remotion promo video. |
| `make ci-swift-check` | `swift format lint --strict`, `swift build` and the test suite in `apps/macos`. |
| `make ci-swift` | `ci-swift-check` plus a full `build.sh` run with bundle-layout and codesign assertions on the produced app. |

### macOS app

| Target | What it does |
| --- | --- |
| `make build` | Builds the app and runs it from `dist/`. Accepts `PR=<n>` or `BRANCH=<name>` to build that ref. |
| `make install` | Builds and copies to `/Applications`, then launches. Same `PR` / `BRANCH` flags. |
| `make reset` | Runs `reset.sh`: clears app state for a clean-slate run. |
| `make reinstall` | `reset` followed by `install`. |
| `make release V=1.8.0` | Full release: bumps plist versions, commits, tags, builds the DMG + installer + Sparkle appcast, pushes and creates the GitHub release. Blocks unless `gh` is authenticated and the Sparkle key is set. |

### Web & database

| Target | What it does |
| --- | --- |
| `make web-dev` | Starts the Next.js dev server in `apps/web`. |
| `make db-generate` | Generates Drizzle migrations from the schema. |
| `make db-push` | Pushes the schema straight to the database. |
| `make db-studio` | Opens Drizzle Studio. |
| `make db-migrate FILE=...` | Applies one SQL migration file with `psql`, using `DATABASE_URL` from `apps/web/.env` (with `channel_binding` stripped). |

### Environment & licensing

| Target | What it does |
| --- | --- |
| `make env-check` | Verifies `apps/web/.env` contains every required variable. |
| `make env-generate` | Generates values for missing env vars. |
| `make env-rotate` | Rotates secrets; dry-run by default, pass `CONFIRM=1` to apply. |
| `make env-sync` | `env-check`, then syncs env vars to the deployment; dry-run unless `CONFIRM=1`. |
| `make license MACHINES=3 LABEL=... NAME=... EMAIL=... PHONE=...` | Mints a license for the given machine count and licensee. |

### Misc

| Target | What it does |
| --- | --- |
| `make loc` | Lines-of-code report for tracked files via `cloc`. |

</details>

## Release & updates

Bump `CFBundleShortVersionString` in `apps/macos/Resources/Info.plist` and
`HelperInfo.plist`, then push a matching tag:

```bash
git tag v1.8.0 && git push origin v1.8.0
```

The Release workflow builds `Edith-v1.8.0.dmg` (drag-to-Applications layout)
and attaches it to the GitHub release.

`make release V=1.8.0` automates the whole sequence, including the Sparkle
appcast and installer DMG.

### Signing the release (so permissions survive reinstalls)

macOS ties each permission grant (Screen Recording, Accessibility, Calendar,
...) to the app's code-signing designated requirement. A grant survives a
reinstall only if the new build still satisfies it. An ad-hoc signature's
requirement is pinned to the binary hash, which changes every build, so an
ad-hoc DMG resets every permission on each reinstall. Signing with a stable
Apple identity gives a requirement that is identical across versions, so grants
persist just like any app you update normally.

`build.sh` signs with the first available of a "Developer ID Application",
self-signed "Edith Dev", or "Apple Development" identity, so local builds,
`--install` reinstalls, and the released DMG all sign the same way.

By default `codesign` writes a requirement that names the exact leaf
certificate, so grants still evaporate when that certificate is re-issued or
when you swap an "Apple Development" identity for the "Developer ID
Application" one used to notarize. When the identity carries a team id,
`build.sh` instead pins the requirement to bundle id + team id:

```
identifier "com.pulkit.edith" and anchor apple generic
  and certificate leaf[subject.OU] = "<team id>"
```

Every certificate your team owns satisfies that, so grants survive certificate
renewals and the move to Developer ID. Because macOS stores the requirement at
the moment a permission is granted, grants made by an older build keep the old
certificate-specific requirement; reset them once after installing a build made
with this change so the durable requirement is what gets recorded:

```bash
tccutil reset All com.pulkit.edith
tccutil reset All com.pulkit.edith.statusbar
```

For the DMG
to match your local builds, CI must sign with the same certificate. Export the
identity you sign with locally and store it as two repository secrets:

```bash
security export -k ~/Library/Keychains/login.keychain-db -t identities \
  -f pkcs12 -P "<pick-a-password>" -o cert.p12
gh secret set MACOS_CERT_P12 < <(base64 -i cert.p12)
printf %s "<pick-a-password>" | gh secret set MACOS_CERT_PASSWORD
```

- `MACOS_CERT_P12` - base64 of the exported `.p12` (certificate + private key).
- `MACOS_CERT_PASSWORD` - the password set on that `.p12`.

With the secrets present the Release workflow imports the certificate into a
temporary keychain and `build.sh` signs with it automatically; without them it
still builds an ad-hoc DMG. An "Apple Development" identity is not notarized, so
the first launch of a freshly downloaded DMG needs a right-click -> Open (or
`xattr -dr com.apple.quarantine Edith.app`); permission grants still persist
across every reinstall after that.
