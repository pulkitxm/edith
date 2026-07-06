# <img src="apps/macos/Resources/appicon.png" width="30" align="top" alt=""> Edith

A native SwiftUI menu bar app for the Mac — a dark, minimal personal control
center built to run 24/7 on near-zero resources.

## Features

- **Rate-limit rings** — session (5h) and weekly usage as live animated gauges with second-by-second countdowns and a 24h history spark.
- **Menu-bar limits** — optional second menu bar readout of session + weekly %, tinted by a time-aware risk model.
- **Smart notifications** — threshold, ahead-of-pace, burning-hot, back-to-green and pre-reset alerts, all optional, with a self-diagnosing test button.
- **Activity heatmap** — GitHub-style daily spend calendar across your full history.
- **Token & cost stats** — today / week / billing cycle, filterable by agent (Claude Code, Codex, OpenCode…).
- **Full dashboard** — a native window with KPIs, per-day / model / source / project / hourly charts, a sortable model table and an activity heatmap, all interactive; refreshed by a self-contained collector bundled in the app.
- **Music player** — plays your local music folder with thumbnails, drag-to-seek, fades, auto-advance and media keys.
- **System tools** — prevent-sleep toggle and a keyboard-cleaning lock with a 60s auto-restore.
- **Global shortcut** — toggle the panel from anywhere (default ⌥⌘E), re-recordable.
- **Presenter mode** — blurs track names and spend figures for screen sharing.
- **Local-first** — usage data never leaves your Mac; optional iCloud backup that merges across machines.

## Resource use

Built to idle cheaply. Measured on an Apple M4 Pro — CPU as a share of one core
(the convention Activity Monitor uses), memory as physical footprint:

| State | CPU | Memory |
| --- | --- | --- |
| Idle, panel closed | ~0% | ~22 MB |
| Music playing, panel closed | ~1% | ~40 MB |
| Music playing, panel open (visualizer on screen) | ~29% | ~42 MB |
| Paused | <1% | ~40 MB |

Work stops when it isn't seen: disabling a tab tears down its timers, observers
and background jobs entirely, and per-frame UI (the music visualizer and
scrubber) only redraws while the panel is open and playing — so listening in the
background costs just the audio decode.

## Build & install

```bash
cd apps/macos
./build.sh            # build + run from dist/
./build.sh --install  # build + copy to /Applications + launch
./test.sh             # run the Swift test suite
```

Needs only Xcode Command Line Tools (Swift 6).

`build.sh` also assembles a small `EdithMenuBar.app` helper nested inside
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
