# `ed extensions`

Extensions are the features Edith can turn on and off: panel tabs, menu bar
items, and the things that run in the background. Each one is a single boolean
in Edith's shared preferences, and `ed extensions` is the registry in front of
those booleans. They get their own verbs rather than living only under
`ed config` because turning one on can need a macOS permission Edith has not
been granted yet, and because the registry knows the readable name, the group
and the permission list that a bare key does not.

Everything here reads and writes
`UserDefaults(suiteName: "com.pulkit.edith.shared")`, so every settings command
works whether or not Edith is running. A write posts `settingsChanged`, so a
running app picks the change up live and a closed one picks it up the next time
it launches. Readiness commands also inspect the tools, permissions, helper,
platform support, configured machines and available backends an extension uses.
The lifecycle sheet's documentation buttons and `ed app open-link
extension-doc:<extension>:<document>` resolve through the same shared link
catalog. `ed app links` lists every available documentation id.

The settings pane, onboarding flow, `enable`, `disable`, `setup`, and extension
tool installation all execute through the same EdithKit operation layer. The
pane uses its permission-aware policy, which leaves a required-permission toggle
off until the grant arrives. The CLI uses the noninteractive policy, which
enables immediately and reports missing grants in plain text or JSON.

## At a glance

| Command | What it does |
| --- | --- |
| `ed extensions` | Runs `ls`, which is the default subcommand |
| `ed extensions ls` | Every extension, its group, and whether it is on. `list` is an alias |
| `ed extensions enable <id>` | Turns one on, and names on stderr any required permission still missing |
| `ed extensions disable <id>` | Turns one off |
| `ed extensions info <id>` | Describes one: name, summary, key, group, state, permissions |
| `ed extensions status [id]` | Summarises readiness for one extension or all twenty-two |
| `ed extensions setup <id>` | Enables one and reports the setup that remains |
| `ed extensions verify <id>` | Runs every readiness check for one extension |
| `ed extensions doctor [id]` | Diagnoses one extension or all twenty-two, with recovery commands |

The Extensions pane and each extension settings modal use these same typed read
operations. Marketplace browsing maps to `ls`, opening a modal maps to `info`,
the readiness section maps to `status`, Check again maps to `verify`, and the
displayed failure and recovery guidance maps to `doctor`. The UI and CLI share
the same registry lookup, enabled-state read, lifecycle probe, and registry
ordering.

The modal's enable switch, permission buttons, extension preferences, setup
links, test actions, and feature-specific open actions also use the same typed
operations as their command-line equivalents.

## The registry

`ExtensionRegistry.entries` in EdithCore is the single list every command here
walks, and its order is the order `ls` prints. Twenty-two entries, in this order:

| ID | Name | Group | What it does |
| --- | --- | --- | --- |
| `attention` | Attention | Utilities | Understand where your time goes and protect focused work |
| `usage` | Agent Usage | Agent | Claude and Codex limits, usage stats, and alerts |
| `herdr` | Herdr | Agent | Live Herdr sessions on this Mac and your SSH machines |
| `quinjet` | Quinjet | Agent | Pull request and live workspace review in a native terminal |
| `seoAudit` | Site Audit | Utilities | Crawl sitemaps, inspect page metadata, and keep every run local |
| `system` | System | System | Running apps, prevent sleep, and the keyboard-cleaning lock |
| `appMaintenance` | App Maintenance | System | Packages, verified installs, updates, and review-first removal |
| `machines` | Machines | System | Your other computers over SSH: stats, files, Docker, and a terminal |
| `database` | Database | Utilities | Guarded database exploration and production mutations |
| `companion` | Companion | Agent | Your notes, voice memos and activity, remembered and searchable |
| `systemStats` | CPU & Memory in menu bar | System | Live CPU and memory readout as a menu bar item |
| `micMute` | Mic Mute | System | Mute every microphone system-wide with ⌘⇧M or the menu bar icon |
| `lidAwake` | Lid Awake | System | Keeps this Mac running with the lid shut, on battery and unplugged |
| `music` | Music | Media | Plays your local music folder, with media keys |
| `calendar` | Calendar | Media | Shows your schedule in the panel and the app |
| `notchShelf` | Notch Shelf | Media | File shelf, now playing, camera, and alerts around the notch |
| `clipboard` | Clipboard | Utilities | Clipboard history with instant paste |
| `keystrokeHighlight` | Keystroke Highlight | Utilities | Shows each key press on screen for demos |
| `focusDim` | Focus Dim | Utilities | Dims everything behind your active app |
| `presenter` | Presenter | Utilities | Blurs sensitive numbers while sharing your screen |
| `emoji` | Emoji Picker | Utilities | Every macOS emoji on a hotkey |
| `colorPicker` | Color Picker | Utilities | System loupe on a hotkey, sampled color to your clipboard |

The same twenty-two, with what each one is made of. `Key` is the preference the app
reads, and the key `ed config` writes for the same feature. `Featured` marks the
eleven the welcome tour shows before you ask it for all of them.

| ID | Key | Featured | Required permissions | Optional permissions | Required tools | Optional tools |
| --- | --- | --- | --- | --- | --- | --- |
| `attention` | `tabAttentionEnabled` | yes | none | none | none | none |
| `usage` | `tabUsageEnabled` | yes | none | `notifications` | `claude`, `codex` | none |
| `herdr` | `tabHerdrEnabled` | yes | none | none | none | none |
| `quinjet` | `tabQuinjetEnabled` | yes | none | none | `quinjet` | none |
| `seoAudit` | `tabSEOAuditEnabled` | no | none | none | none | none |
| `system` | `tabSystemEnabled` | yes | none | `accessibility`, `inputMonitoring` | none | none |
| `appMaintenance` | `appMaintenanceEnabled` | yes | none | none | none | `homebrew` |
| `machines` | `tabMachinesEnabled` | yes | none | `notifications` | none | none |
| `database` | `tabDatabaseEnabled` | yes | none | none | none | none |
| `companion` | `tabCompanionEnabled` | no | none | none | none | none |
| `systemStats` | `menuBarSystemStats` | no | none | none | none | none |
| `micMute` | `micMuteEnabled` | no | none | none | none | none |
| `lidAwake` | `lidAwakeEnabled` | no | none | none | none | none |
| `music` | `tabMusicEnabled` | no | none | none | none | `yt-dlp` |
| `calendar` | `tabCalendarEnabled` | no | `calendar` | none | none | none |
| `notchShelf` | `notchShelfEnabled` | yes | none | `applicationAudio`, `bluetooth`, `camera`, `automation` | none | none |
| `clipboard` | `clipboardEnabled` | yes | none | `accessibility` | none | none |
| `keystrokeHighlight` | `keystrokeHighlightEnabled` | yes | `inputMonitoring` | none | none | none |
| `focusDim` | `focusDimEnabled` | no | `screenRecording` | none | none | none |
| `presenter` | `presenterEnabled` | no | `screenRecording` | none | none | none |
| `emoji` | `emojiEnabled` | no | none | `accessibility` | none | none |
| `colorPicker` | `colorPickerEnabled` | no | `screenRecording` | none | none | none |

The JSON form also exposes the platform capability registry. Capabilities are
not permission ids. They say which implementation an extension requires from
the current platform, and which missing implementations merely degrade it:

| ID | Required capabilities | Optional capabilities |
| --- | --- | --- |
| `attention` | `runningApplications` | none |
| `usage` | `usageCollection` | `notifications` |
| `herdr` | `herdrSessions` | none |
| `quinjet` | `localTerminal` | none |
| `seoAudit` | `siteAuditing` | none |
| `system` | `runningApplications` | `preventSleep`, `inputSuppression` |
| `appMaintenance` | `runningApplications` | `packageManagement` |
| `machines` | `machineManagement` | `notifications` |
| `database` | `databaseBroker` | none |
| `companion` | `companionService` | none |
| `systemStats` | `systemMetrics` | none |
| `micMute` | `microphoneControl` | `globalShortcuts` |
| `lidAwake` | `preventSleep` | none |
| `music` | `localMusicPlayback` | `mediaControls` |
| `calendar` | `calendarEvents` | none |
| `notchShelf` | `fileShelf` | `applicationAudio`, `bluetoothMonitoring`, `cameraPreview`, `externalMediaControl` |
| `clipboard` | `clipboardHistory` | `globalPaste`, `globalShortcuts` |
| `keystrokeHighlight` | `keystrokeObservation` | none |
| `focusDim` | `windowDimming` | none |
| `presenter` | `screenShareDetection` | none |
| `emoji` | `emojiInsertion` | `globalShortcuts` |
| `colorPicker` | `screenColorSampling` | `globalShortcuts` |

An id is matched exactly and case-insensitively against the `ID` column first,
then against the `Key` column, so `ed extensions info clipboard`,
`ed extensions info CLIPBOARD` and `ed extensions info clipboardEnabled` are the
same command. There is no prefix matching here: unlike a machine name, `clip`
fails with the full list of ids rather than guessing.

## Commands

- [`ed extensions ls`](./ls.md)
- [`ed extensions enable`](./enable.md)
- [`ed extensions disable`](./disable.md)
- [`ed extensions info`](./info.md)
- [`ed extensions status`](./status.md)
- [`ed extensions setup`](./setup.md)
- [`ed extensions verify`](./verify.md)
- [`ed extensions doctor`](./doctor.md)

## Readiness states

`info`, `status`, `setup`, `verify` and `doctor` use one readiness probe. The
Extensions settings sheet renders the same report. Its phases are stable JSON
values:

| Phase | Meaning |
| --- | --- |
| `disabled` | The extension is off, so dependent checks are skipped |
| `needsSetup` | The extension is on but a permission, tool, helper, machine, or backend is missing |
| `ready` | Every required check passed |
| `degraded` | Required checks passed, but an optional check or part of a backend is unhealthy |
| `unavailable` | The current platform does not implement a required capability |
| `failed` | A configured backend or runtime dependency failed |

Each check has a `passed`, `warning`, `failed`, or `skipped` status. Failed
checks carry a `recoveryCommand` where the CLI can name a safe next action.
`verified` is true only when the phase is `ready`.

Readiness and runtime are separate dimensions. `state.runtimePhase` uses these
stable JSON values:

| Runtime phase | Meaning |
| --- | --- |
| `installed` | The core runtime is present and its probes succeeded |
| `uninstalled` | A required executable or adapter is absent, whether the extension is on or off |
| `empty` | The runtime is installed and ready but has no content or sessions yet |
| `loading` | Runtime discovery is still in progress |
| `unsupported` | The current platform cannot provide a required capability |
| `error` | A present executable, backend, or adapter failed its readiness probe |

An optional workflow can make readiness `degraded` without changing runtime
from `installed`. Music without `yt-dlp` is the canonical example: local
playback remains installed, while URL import has an actionable warning.

Every enabled extension also runs a live adapter. The adapter validates its
real storage, operating system service, executable, configuration, or backend
instead of treating a running helper as proof that the feature works. See
[extension runtime detection](./runtime-detection.md) for the full matrix and
agent recovery workflow.

## Exit codes

| Code | When |
| --- | --- |
| 0 | the command completed, including a readiness report whose `verified` field is false |
| 2 | the command line was wrong: an unknown flag, or a command that requires an id did not get one |
| 3 | no extension matches the id you named, by id or by defaults key |

An unhealthy extension is data, not a command failure. This keeps JSON intact
for agents and scripts. Read `verified`, `state.phase`, `state.runtimePhase`,
`checks`, and `remediation` to decide what to do next.

## Notes and gotchas

- An unset extension key has one effective fallback across `ed config`,
  `ed extensions`, onboarding, and the app: off. A fresh install can therefore
  leave unselected keys absent without the reporting surfaces disagreeing.
- Every extension is also an ordinary `ed config` boolean, and both paths write
  the same primary key in the same store. The extension verbs also preserve
  lifecycle dependencies: enabling Agent Usage restores the selected provider
  when both providers are off, and disabling System turns Prevent Sleep off.
  Only the extension verbs know to mention a missing permission.
  Related settings sit in that extension's own config group, so
  `ed config ls --group clipboard` and `--group notch`, `--group focusdim` or
  `--group colorpicker` give you the rest of the knobs.
- The permission check reads what the app last mirrored into preferences, not
  live TCC state, because a command line process cannot read another
  application's grants. If a note names a permission you know you have already
  granted, run `ed permissions refresh` and try again.
- `setup` never opens the app, a permission prompt, or another interactive UI.
  It installs tools only when `--install-tools` is explicit. Use `--dry-run` to
  project the enabled state and required tool plan without changing anything.
- `applicationAudio`, `bluetooth` and `automation` are granted by macOS on first
  use and have no mirrored key, so they are always reported as not granted. That
  is why they appear only as optional permissions, on `notchShelf`, and never
  in `missingRequiredPermissions`.
- `requiredTools` contains core setup blockers. `optionalTools` contains tools
  for additional workflows. Onboarding and `setup --install-tools` provision
  only required tools. Music exposes `yt-dlp` as optional because local library
  playback works without URL import. Agent Usage always lists both registered
  providers, although the app's provisioning sheet can hide a provider disabled
  in limits settings.
- Ordering is stable and worth relying on: the array `--json` emits follows the
  registry's own order, and only the keys inside each object are sorted, which
  is why the output diffs cleanly between runs.
- Enabling from `ed` does not stamp the `extensionPermissionsSeen.<id>` marker
  the Extensions pane writes when you flip a switch there. The pane still reads
  it, but `ExtensionPermissionFlow.decision` ignores the value, so the two paths
  still end up equivalent.
- Completion offers every registry id for `enable`, `disable`, `info`, `status`,
  `setup`, `verify`, and `doctor`. It offers every provisionable tool id for
  `ed tools install`, including tools added by a new extension.
- The `ls` renderer flattens tabs and newlines to spaces and drops control
  characters, so a row is always one line, and the last column is never padded.

## Where to go next

- [`ed permissions`](../permissions/README.md) for granting what an extension needs
- [`ed config`](../config/README.md) for the settings an extension exposes once it is on
- [`ed tools`](../tools/README.md) for the command line tools named by
  `requiredTools` and `optionalTools`
- [Extension runtime detection](./runtime-detection.md) for every live probe and
  recovery path
- [Quinjet setup](https://github.com/pulkitxm/edith/blob/main/docs/quinjet.md) for terminal, theme, install and verification details
- [All `ed` commands](../README.md)
