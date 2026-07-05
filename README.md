# <img src="apps/macos/Resources/appicon.png" width="30" align="top" alt=""> Edith

A native SwiftUI menu bar app for the Mac — a dark, minimal personal control
center built to run 24/7 on near-zero resources.

## Features

- **Rate-limit rings** — session (5h) and weekly usage as live animated gauges with second-by-second countdowns and a 24h history spark.
- **Menu-bar limits** — optional second menu bar readout of session + weekly %, tinted by a time-aware risk model.
- **Smart notifications** — threshold, ahead-of-pace, burning-hot, back-to-green and pre-reset alerts, all optional, with a self-diagnosing test button.
- **Activity heatmap** — GitHub-style daily spend calendar across your full history.
- **Token & cost stats** — today / week / billing cycle, filterable by agent (Claude Code, Codex, OpenCode…).
- **One-click dashboard** — opens the full HTML usage dashboard in the browser, carrying your filters.
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
