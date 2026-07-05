# <img src="Assets/appicon.png" width="30" align="top" alt=""> Edith

Native SwiftUI menu bar app for the Mac (the eyeglasses icon next to the
system controls) - a personal control center. Dark, minimal, built to run
24/7 on near-zero resources.

## Features

- **Rate limit rings** - session (5h) and weekly usage as animated gauges
  with live second countdowns; auto-refresh every 5 min, instantly on wake;
  a 24h history mini-chart under the rings
- **Limits in the menu bar** - optional second menu bar item with the
  session + weekly percentages, tinted by a time-aware risk model (Smart
  Color) or a fixed color (white/black); click opens the panel
- **Limit notifications** - threshold escalations with pacing-aware copy,
  ahead-of-pace and burning-hot alerts, back-to-green recovery, reminders
  before session/weekly resets, token-expired nudge - all configurable in
  Settings, off by default; a self-diagnosing test-notification button
  reports Delivered / Blocked / Permission not granted / Failed
- **Activity heatmap** - GitHub-style daily spend calendar, full history,
  horizontally scrollable
- **Token & cost stats** - today / yesterday / this week / billing cycle,
  filterable by agent source (Claude Code, Codex, OpenCode, …)
- **Dashboard link** - one click opens the full HTML dashboard in the
  browser, carrying the panel's filters; ↻ runs the data pipeline with a
  collapsible live log
- **Music player** - plays whatever is in the music folder (mp3/m4a/mp4/webm/
  …), thumbnails, drag-to-seek, fades, auto-advance, media keys + Now Playing
- **System tools** - prevent-sleep toggle (IOKit assertion) and a keyboard
  cleaning lock that blocks every key, media row included, with an overlay,
  Done button, and 60s auto-restore
- **Global shortcut** - toggle the panel from anywhere (default ⌥⌘E),
  re-recordable in settings; Esc or clicking away closes it
- **Settings screen** - enable/disable tabs (an off tab's module is never
  loaded), app-wide theme color, presenter view that blurs sensitive values
  for screen sharing; the pane scroll-caps at ~640pt, with detail rows
  (Limits, Notifications) tucked behind View more disclosures
- **Settings & data backup** - settings, `usage.json`, and the limits
  history mirror to Application Support and, with the iCloud toggle on, to
  iCloud Drive; the append-only limits log is *merged* (not overwritten), so
  multiple Macs combine rather than clobber. Per-file toggles in Settings
  (expand the Back-up-to-iCloud row). A fresh install adopts the backup out
  of the box - it inherits the iCloud settings on first launch, no toggle
- **Agent Usage** code lives in `Sources/Edith/Usage/`, **Music** in
  `Sources/Edith/Music/` - one folder per feature so future tabs slot in.

## Layout

| Path | What it is |
|---|---|
| `Package.swift`, `Sources/Edith/` | The app - plain SwiftUI executable, no Xcode project. |
| `build.sh`, `Info.plist`, `Assets/`, `AppIcon.icns` | Build script, bundle bits, icon + logo artwork. |
| `dashboard/` | The self-contained usage dashboard + data pipeline (`cc-update` → `data/usage.json` → `dashboard.html`). See `dashboard/README.md`. |
| `local/` | Gitignored personal files: `local/music/`, `local/extras/`. |
| `docs/` | Design notes and specs. |

## Build & install

```bash
./build.sh            # build + run from dist/
./build.sh --install  # build + copy to /Applications + launch
./test.sh             # run the Swift test suite
```

Needs only Xcode Command Line Tools (Swift 6). The bundle is assembled by the
script and ad-hoc signed. `test.sh` wraps `swift test` with the CLT-bundled
`Testing.framework` search paths, which plain `swift test` misses without a
full Xcode install.

## Data & paths

- Usage data never leaves the machine: `dashboard/data/` and the generated
  `dashboard/dashboard.html` are gitignored; the template's data block is
  empty. Refresh locally with `dashboard/cc-update`. The two data files
  (`usage.json`, `limits-history.jsonl`) can still be backed up to your own
  iCloud Drive (`Settings` toggle) - the backup channel is iCloud, not git.
- The app finds everything relative to this repo. If the repo moves:
  `defaults write com.pulkit.edith repoPath /new/path`
  (settings from the old com.pulkit.control-center id are imported once on
  first launch; macOS 26's menu bar manager had block-listed that id).

## Notes

- Appearance: system / light / dark (settings dropdown); panel centers under
  the menu bar icon.
- Runs 24/7 as a login item: timers pause during sleep, a wake observer
  refreshes immediately, no polling beyond the 5-minute limits call, stats
  re-parse only when `usage.json`'s mtime changes, per-second countdowns tick
  only while the panel is visible.
- On a 429 from the usage endpoint the poll backs off (Retry-After or 30 min).
- Presenter view (gear menu) blurs track names and spend figures for screen
  sharing.
