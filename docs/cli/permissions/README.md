# `ed permissions`

macOS hands privacy grants to an application bundle, not to a process, so the
nine permissions Edith uses belong to the Edith app and never to `ed`. A command
line process cannot read another bundle's TCC state, and it must not try. `ed`
therefore reports the mirror the app writes into the shared defaults suite every
time it re-reads the real state, and hands anything that needs a live system
prompt back to the app.

Reach for this group when an extension is on but doing nothing:
`ed permissions ls --attention` names the grant that is holding it up, in one
line, without you opening System Settings to find out.

## At a glance

| Command | What it does |
| --- | --- |
| `ed permissions ls` | Print every permission with its mirrored state, whether it blocks an enabled extension, and which enabled extensions use it |
| `ed permissions request <permission>` | Ask the running app to raise the macOS prompt for one permission, wait, then report whether the grant landed |
| `ed permissions refresh` | Ask the running app to re-read the real TCC state, then print the refreshed mirror |

`ls` is the default subcommand, so a bare `ed permissions` prints the table.
`list` is an accepted alias for `ls`.

## The permissions Edith uses

There are exactly nine and they are fixed in the binary. `ed permissions
request` is the only command in this group that takes one of their ids; it
matches case-insensitively, and an id that is not one of these exits 3 with the
full list as the hint.

| Id | Where it lives in System Settings | What Edith needs it for | Used by |
| --- | --- | --- | --- |
| `calendar` | Privacy & Security > Calendars | Read and show your schedule in Calendar | required by `calendar` |
| `notifications` | Notifications | Usage limit, pacing and reset alerts | optional for `usage`, `machines` |
| `accessibility` | Privacy & Security > Accessibility | Clean keys, and clipboard instant paste | optional for `system`, `clipboard` |
| `inputMonitoring` | Privacy & Security > Input Monitoring | Block key presses while Clean keys is locking the keyboard | optional for `system` |
| `fullDisk` | Privacy & Security > Full Disk Access | Reach local service credentials and usage data | nothing declares it |
| `screenRecording` | Privacy & Security > Screen Recording | Detect shared content, and sample colours from the screen | required by `focusDim`, `presenter`, `colorPicker` |
| `camera` | Privacy & Security > Camera | The Notch Shelf camera preview | optional for `notchShelf` |
| `bluetooth` | Edith opens no pane, granted on first use | Notch Shelf device connection alerts | optional for `notchShelf` |
| `automation` | Edith opens no pane, granted on first use | Notch Shelf controlling external playback | optional for `notchShelf` |

For the seven that can be requested, the `reason` string in `--json` is the same
sentence the Permissions pane shows under each row, so the CLI and the UI cannot
describe those grants differently. `bluetooth` and `automation` are the
exception: the pane prefers their first-use explanation, which is the same
sentence `request` prints as its hint when it refuses them.

How each one is observed, and what asking for it actually does:

| Id | Mirror setting | How the app observes the real state | What `request` makes the app do |
| --- | --- | --- | --- |
| `calendar` | `permCalendarGranted` | the event store's own authorisation status | ask `EKEventStore` for full access to events, and open the Calendars pane |
| `notifications` | `permNotificationsGranted` | `UNUserNotificationCenter`, counting authorised and provisional as granted | request alert and sound authorisation, and open the Notifications pane |
| `accessibility` | `permAccessibilityGranted` | `AXIsProcessTrusted()` | raise the trusted-process prompt, and open the Accessibility pane |
| `inputMonitoring` | `permInputMonitoringGranted` | `CGPreflightListenEventAccess()` | `CGRequestListenEventAccess()`, and open the Input Monitoring pane |
| `fullDisk` | `permFullDiskGranted` | try to open `~/Library/Application Support/com.apple.TCC/TCC.db` for reading | open the Full Disk Access pane, because macOS offers no prompt for it |
| `screenRecording` | `permScreenRecordingGranted` | `CGPreflightScreenCaptureAccess()` | `CGRequestScreenCaptureAccess()`, and open the Screen Recording pane |
| `camera` | `permCameraGranted` | `AVCaptureDevice` video authorisation | ask `AVCaptureDevice` when the state is undetermined, open the Camera pane otherwise |
| `bluetooth` | none | not observed | refused, exit 4 |
| `automation` | none | not observed | refused, exit 4 |

`calendar` is the odd one out in that table. Its mirror is written by the main
Edith window rather than by the menu bar helper, and the helper is what answers
`request` and `refresh`, so with only the menu bar running the calendar row
keeps whatever the window last stored. The prompt still comes up; the mirror
catches up the next time the window is open. The other six move under a refresh.

`bluetooth` and `automation` have no mirror setting because macOS grants them
the first time the code that needs them runs, and there is no ahead-of-time
prompt to raise. They therefore report `granted` as `false` for as long as they
exist, which is a statement about what Edith knows rather than about what macOS
has decided. `ls` says `on first use` for them instead of `no`; `refresh` says
`no`.

`fullDisk` is in the catalogue but no extension declares it, so it never blocks
anything and never appears under `--attention`. Request it by hand when a
feature tells you to.

The seven mirror settings are ordinary read-only keys in the `permissions`
group, so `ed config ls --group permissions` shows the same booleans and writing
one exits 1. That group also holds `permissionsFilter`, which is the filter the
Permissions pane opens with, and is writable.

## Commands

## Commands

- [`ed permissions ls`](./ls.md)
- [`ed permissions request`](./request.md)
- [`ed permissions refresh`](./refresh.md)

## Exit codes

| Code | What produces it in this group |
| --- | --- |
| 0 | Any successful run, including a `request` whose grant did not land inside the wait |
| 2 | An unknown flag, or `ed permissions request` with no permission named |
| 3 | `ed permissions request <permission>` where the id is not one of the nine, with the full list as the hint |
| 4 | `ed permissions request bluetooth` or `automation`; `request` or `refresh` while the Edith menu bar app is closed |

`ed permissions ls` has no failure path and always exits 0.

## Notes and gotchas

- Nothing in this group reads the real TCC database. `ls` reads the mirror,
  `refresh` asks the app to update the mirror, `request` asks the app to raise a
  prompt. The grants belong to the Edith bundle, and a mirror is the only honest
  thing a separate process can report.
- On a Mac where Edith has never run, every mirror key is missing and therefore
  reads false, so `ls` reports nothing as granted. `appRunning: false` in the
  same document is what distinguishes that from a real answer.
- `--attention` looks at `requiredBy` only. A missing permission that is merely
  optional for an enabled extension degrades that extension rather than blocking
  it, so it never shows as `blocking` and never survives the filter.
- The permission ids are exactly the ids shell completion offers, and the same
  ids `ed extensions info <id> --json` prints under `requiredPermissions`,
  `optionalPermissions` and `missingRequiredPermissions`.
- Turning an extension on never waits for its permission. `ed extensions enable`
  enables it and names the missing grant on stderr, and this group is where you
  go next.
- Other commands point back here when macOS is what is stopping them. A calendar
  read with the grant missing exits 4 and hints at
  `ed permissions request calendar`, which is this same failure reached by a
  different route.
- `ed permissions request` opens System Settings on the Mac running Edith. That
  is the app's doing rather than the CLI's, and it happens whether you typed the
  command locally or over SSH.
- Both writing verbs talk to the app over its own distributed notification bus
  and neither shells out to it. `request` posts the permission's grant name;
  both post the shared refresh name afterwards.

## Where to go next

- [`ed extensions`](../extensions/README.md) for the extensions these permissions gate.
- [`ed config`](../config/README.md) for the read-only `perm*Granted` mirror keys and
  `permissionsFilter`.
- [`ed calendar`](../calendar/README.md) for the one read that fails outright without
  its grant.
- [`ed app`](../app/README.md) for `ed app relaunch`, which a new grant usually needs.
- [All `ed` commands](../README.md).
