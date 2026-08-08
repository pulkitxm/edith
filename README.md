# <img src="apps/macos/Sources/Edith/Resources/appicon.png" width="30" align="top" alt=""> Edith

A native SwiftUI menu bar app for the Mac: a dark, minimal control center that
replaces a shelf of single-purpose utilities and idles at about 22 MB.

Free and open source under the [GPL-3.0](LICENSE). Every feature is in the one
app. No licence key, no account, no paid tier.

**[Download for macOS](https://github.com/pulkitxm/edith/releases/latest/download/Edith.dmg)**
· [edith.pulkit.page](https://edith.pulkit.page)

Requires macOS 14 or later on Apple Silicon.

## Features

**Claude and Codex usage**

- **Rate-limit rings** - session (5h) and weekly usage as live gauges with second-by-second countdowns and a 24h history spark.
- **Menu bar readout** - session and weekly percentages in the menu bar, tinted by a time-aware risk model.
- **Alerts** - threshold, ahead-of-pace, burning-hot, back-to-green and pre-reset notifications, all optional.
- **Dashboard** - KPIs with per-day, model, source, project and hourly charts, plus a sortable model table.
- **Activity heatmap** - GitHub-style daily spend calendar across your full history.
- **Project drilldown** - spend by project, worktree and chat, across both agents.
- **Fleet usage** - the same collector runs on your SSH machines and folds their agents in as their own sources, so the totals cover every box you code on.

**Everything else on the shelf**

- **Music player** - your local music folder with thumbnails, drag-to-seek, fades, auto-advance and media keys; also controls Spotify and Apple Music.
- **Clipboard history** - a global paste panel with search and paste-in-place.
- **Color picker** - system-wide eyedropper on a hotkey, with swatch history.
- **Notch shelf** - the notch becomes a hover-to-open shelf for drag-and-drop file staging, now-playing controls and a camera check.
- **Calendar** - your agenda grouped by day, with one-tap join links.
- **Audio mixer** - per-app volume control.
- **Mic mute** - system-wide microphone kill switch with a menu bar indicator.
- **Focus dim** - dims every screen except the window you are working in.
- **System tools** - prevent-sleep toggle, CPU and memory readout, and a keyboard-cleaning lock that auto-restores after 60s.
- **Disk cleaner** - scans build caches, package managers and old logs.
- **Global shortcut** - toggle the panel from anywhere, ⌥⌘E by default and re-recordable.

## Command line

Installing Edith installs `ed`, a first-class CLI that reaches everything the UI
does. `edh` and `edith` are the same binary. Full reference: [docs/cli.md](docs/cli.md),
or run `ed guide` for the built-in manual.

```
ed config set preventSleep true     every setting the UI exposes, applied live
ed extensions enable machines       turn features on and off
ed usage limits --json              the same numbers the rings show
ed system stats --follow            this Mac, sampled continuously
ed machines ls                      the computers Edith can reach over SSH
ed tuf docker ps                    run anything on one of them
```

Every read command takes `--json`, stdout is exactly one document, logs go to
stderr, and exit codes are reliable, so an agent can drive Edith headlessly.
`ed completions install` sets up zsh, bash and fish; after a machine name,
completion asks that machine what it would have offered, so `ed tuf docker <TAB>`
completes docker's own subcommands.

## Privacy

Usage data never leaves your Mac. There is no account and no telemetry.
Rate-limit checks go directly from your machine to your AI provider. Optional
iCloud backup merges your history across your own Macs and nowhere else.

**Presenter mode** blurs spend figures, track names and calendar entries for
screen sharing, and detects screen shares automatically.

## Performance

Built to sit in the menu bar all day. Measured on an Apple M4 Pro, CPU as a
share of one core:

| State | CPU | Memory |
| --- | --- | --- |
| Idle, panel closed | ~0% | ~22 MB |
| Music playing, panel closed | ~1% | ~40 MB |
| Paused | <1% | ~40 MB |

Disabling a tab tears down its timers and background jobs entirely, per-frame UI
only redraws while the panel is open, and the usage collector caches parses so a
refresh only touches files that changed.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for
building from source, the test suite, and how releases are cut.

## Licence

Edith is free software licensed under the [GNU General Public License v3.0](LICENSE).
You may use, study, modify and redistribute it; any version you distribute must
also be released under the GPL-3.0 with its source available.

Sparkle, used for in-app updates, is distributed under the MIT licence.
