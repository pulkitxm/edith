# `ed extensions`

Extensions are the features Edith can turn on and off: panel tabs, menu bar
items, and the things that run in the background. Each one is a single boolean
in Edith's shared preferences, and `ed extensions` is the registry in front of
those booleans. They get their own verbs rather than living only under
`ed config` because turning one on can need a macOS permission Edith has not
been granted yet, and because the registry knows the readable name, the group
and the permission list that a bare key does not.

Everything here reads and writes
`UserDefaults(suiteName: "com.pulkit.edith.shared")`, so all four commands work
whether or not Edith is running. A write posts `settingsChanged`, so a running
app picks the change up live and a closed one picks it up the next time it
launches. Nothing in this group waits on the app, and nothing in it can exit 4.

## At a glance

| Command | What it does |
| --- | --- |
| `ed extensions` | Runs `ls`, which is the default subcommand |
| `ed extensions ls` | Every extension, its group, and whether it is on. `list` is an alias |
| `ed extensions enable <id>` | Turns one on, and names on stderr any required permission still missing |
| `ed extensions disable <id>` | Turns one off |
| `ed extensions info <id>` | Describes one: name, summary, key, group, state, permissions |

## The registry

`ExtensionRegistry.entries` in EdithKit is the single list every command here
walks, and its order is the order `ls` prints. Fifteen entries, in this order:

| ID | Name | Group | What it does |
| --- | --- | --- | --- |
| `usage` | Agent Usage | Agent | Claude and Codex limits, usage stats, and alerts |
| `herdr` | Herdr | Agent | Live Herdr sessions on this Mac and your SSH machines |
| `system` | System | System | Running apps, prevent sleep, and the keyboard-cleaning lock |
| `machines` | Machines | System | Your other computers over SSH: stats, files, Docker, and a terminal |
| `companion` | Companion | Agent | Your notes, voice memos and activity, remembered and searchable |
| `systemStats` | CPU & Memory in menu bar | System | Live CPU and memory readout as a menu bar item |
| `micMute` | Mic Mute | System | Mute every microphone system-wide with ⌘⇧M or the menu bar icon |
| `lidAwake` | Lid Awake | System | Keeps this Mac running with the lid shut, on battery and unplugged |
| `music` | Music | Media | Plays your local music folder, with media keys |
| `calendar` | Calendar | Media | Shows your schedule in the panel and the app |
| `notchShelf` | Notch Shelf | Media | File shelf, now playing, camera, and alerts around the notch |
| `clipboard` | Clipboard | Utilities | Clipboard history with instant paste |
| `focusDim` | Focus Dim | Utilities | Dims everything behind your active app |
| `presenter` | Presenter | Utilities | Blurs sensitive numbers while sharing your screen |
| `colorPicker` | Color Picker | Utilities | System loupe on a hotkey, sampled color to your clipboard |

The same fifteen, with what each one is made of. `Key` is the preference the app
reads, and the key `ed config` writes for the same feature. `Featured` marks the
six the welcome tour shows before you ask it for all of them.

| ID | Key | Featured | Required permissions | Optional permissions | Required tools |
| --- | --- | --- | --- | --- | --- |
| `usage` | `tabUsageEnabled` | yes | none | `notifications` | `claude`, `codex` |
| `herdr` | `tabHerdrEnabled` | yes | none | none | none |
| `system` | `tabSystemEnabled` | yes | none | `accessibility`, `inputMonitoring` | none |
| `machines` | `tabMachinesEnabled` | yes | none | `notifications` | none |
| `companion` | `tabCompanionEnabled` | no | none | none | none |
| `systemStats` | `menuBarSystemStats` | no | none | none | none |
| `micMute` | `micMuteEnabled` | no | none | none | none |
| `lidAwake` | `lidAwakeEnabled` | no | none | none | none |
| `music` | `tabMusicEnabled` | no | none | none | `yt-dlp` |
| `calendar` | `tabCalendarEnabled` | no | `calendar` | none | none |
| `notchShelf` | `notchShelfEnabled` | yes | none | `bluetooth`, `camera`, `automation` | none |
| `clipboard` | `clipboardEnabled` | yes | none | `accessibility` | none |
| `focusDim` | `focusDimEnabled` | no | `screenRecording` | none | none |
| `presenter` | `presenterEnabled` | no | `screenRecording` | none | none |
| `colorPicker` | `colorPickerEnabled` | no | `screenRecording` | none | none |

The JSON form also exposes the platform capability registry. Capabilities are
not permission ids. They say which implementation an extension requires from
the current platform, and which missing implementations merely degrade it:

| ID | Required capabilities | Optional capabilities |
| --- | --- | --- |
| `usage` | `usageCollection` | `notifications` |
| `herdr` | `herdrSessions` | none |
| `system` | `runningApplications` | `preventSleep`, `inputSuppression` |
| `machines` | `machineManagement` | `notifications` |
| `companion` | `companionService` | none |
| `systemStats` | `systemMetrics` | none |
| `micMute` | `microphoneControl` | `globalShortcuts` |
| `lidAwake` | `preventSleep` | none |
| `music` | `localMusicPlayback` | `mediaControls` |
| `calendar` | `calendarEvents` | none |
| `notchShelf` | `fileShelf` | `bluetoothMonitoring`, `cameraPreview`, `externalMediaControl` |
| `clipboard` | `clipboardHistory` | `globalPaste`, `globalShortcuts` |
| `focusDim` | `windowDimming` | none |
| `presenter` | `screenShareDetection` | none |
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

## Exit codes

| Code | When |
| --- | --- |
| 0 | the extension was listed, described, enabled or disabled, including when `enable` had to warn about a missing permission |
| 2 | the command line was wrong: an unknown flag, or `enable`, `disable` or `info` with no id |
| 3 | no extension matches the id you named, by id or by defaults key |

Nothing in this group produces 1 or 4. There is no app to be unavailable and no
failure mode between "the id exists" and "the boolean is written".

## Notes and gotchas

- The state `ls` and `info` report is `object(forKey:) as? Bool ?? false`, so a
  key that has never been written reads as off. `ed config get` answers the same
  question from the catalogue's fallback instead, which is `true` for
  `tabUsageEnabled` and `tabSystemEnabled`, so on a Mac where Edith has never
  run those two disagree. Upgrading from an older Edith writes a concrete value
  for all fifteen keys on the next launch and they agree again; a fresh install
  only writes the keys you turn on, so an untouched `tabUsageEnabled` keeps
  disagreeing until something writes it.
- Every extension is also an ordinary `ed config` boolean, and both paths write
  the same key in the same store and post the same `settingsChanged`.
  `ed config set clipboardEnabled true` and `ed extensions enable clipboard`
  leave identical state; only the second one knows to mention Accessibility.
  Related settings sit in that extension's own config group, so
  `ed config ls --group clipboard` and `--group notch`, `--group focusdim` or
  `--group colorpicker` give you the rest of the knobs.
- The permission check reads what the app last mirrored into preferences, not
  live TCC state, because a command line process cannot read another
  application's grants. If a note names a permission you know you have already
  granted, run `ed permissions refresh` and try again.
- `bluetooth` and `automation` are granted by macOS on first use and have no
  mirrored key, so they are always reported as not granted. That is why they
  appear only as optional permissions, on `notchShelf`, and never in
  `missingRequiredPermissions`.
- `requiredTools` is reported verbatim from the registry. The app's provisioning
  sheet filters that list by whether the tool is currently wanted, which drops
  `codex` while `codexLimitsEnabled` is off; `ed` does not filter, so `usage`
  always lists both `claude` and `codex`.
- Ordering is stable and worth relying on: the array `--json` emits follows the
  registry's own order, and only the keys inside each object are sorted, which
  is why the output diffs cleanly between runs.
- Enabling from `ed` does not stamp the `extensionPermissionsSeen.<id>` marker
  the Extensions pane writes when you flip a switch there. The pane still reads
  it, but `ExtensionPermissionFlow.decision` ignores the value, so the two paths
  still end up equivalent.
- The `ls` renderer flattens tabs and newlines to spaces and drops control
  characters, so a row is always one line, and the last column is never padded.

## Where to go next

- [`ed permissions`](../permissions/README.md) for granting what an extension needs
- [`ed config`](../config/README.md) for the settings an extension exposes once it is on
- [`ed tools`](../tools/README.md) for the command line tools `requiredTools` names
- [All `ed` commands](../README.md)
