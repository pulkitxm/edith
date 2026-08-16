# `ed app`

`ed app` holds the one-shot verbs the Edith app performs. These are things the
app does once when asked, rather than switches `ed config set` can flip: lock
the keyboard for cleaning, send the test notification, open or quit the window,
ask Sparkle to look for an update, and relaunch after granting a permission.

Edith is two processes with two bundle ids: the menu bar helper,
`com.pulkit.edith.statusbar`, and the main window, `com.pulkit.edith`. Each verb
is a distributed notification addressed to whichever of the two owns the work,
so each needs that process to be running and exits 4 naming the part that is
missing. `clean-keys`, `test-notification` and `open` are answered by the menu
bar helper. `quit`, `check-updates`, `reveal` and `snapshot` are answered by
the main window, because the window and Sparkle both live there. `updates` and
`clear-updates` touch a file, and `relaunch` terminates both bundle ids itself
and launches the app bundle again, so all three work with Edith closed.

Reach for this group when you want the app to do something now. Reach for
`ed config` when you want to change what it does from now on.

## At a glance

| Command | What it does |
| --- | --- |
| `ed app actions` | List the seven one-shot actions, what each needs, and whether it can run right now. Aliased `ed app ls`, and what a bare `ed app` runs. |
| `ed app clean-keys` | Ask the menu bar app to lock the keyboard so it can be wiped without typing. |
| `ed app test-notification` | Ask the menu bar app to send the same test notification the settings pane sends. |
| `ed app open` | Ask the menu bar app to open Edith's main window. |
| `ed app quit` | Quit the main window, leaving the menu bar running. |
| `ed app check-updates` | Ask Sparkle to check for an update now, and report what it found. |
| `ed app updates` | Print the update checks Edith has already made, newest first. |
| `ed app relaunch` | Quit Edith and start it again, which is what a new permission needs. |
| `ed app clear-updates` | Delete the record of past update checks. |
| `ed app reveal` | Show a section of the main window, and optionally a tab inside it. |
| `ed app snapshot` | Capture the app's open windows as PNG files, no screen recording involved. |

## Commands

- [`ed app actions`](./actions.md)
- [`ed app clean-keys`](./clean-keys.md)
- [`ed app test-notification`](./test-notification.md)
- [`ed app open`](./open.md)
- [`ed app quit`](./quit.md)
- [`ed app check-updates`](./check-updates.md)
- [`ed app updates`](./updates.md)
- [`ed app relaunch`](./relaunch.md)
- [`ed app clear-updates`](./clear-updates.md)
- [`ed app reveal`](./reveal.md)
- [`ed app snapshot`](./snapshot.md)

## Exit codes

| Code | What produces it here |
| --- | --- |
| 0 | The command did what it says, including a request that was sent but never confirmed, `check-updates --no-wait` with no answer, `updates` with an empty log, and `actions` when nothing is running. |
| 1 | `relaunch` could not finish the work: Edith was still running after the force quit, or the launch itself threw. Also `snapshot` when no visible window rendered. |
| 2 | The command line was wrong: an unknown flag, an unknown subcommand, or `--limit` at zero or below on `ed app updates`. |
| 3 | `reveal` named a section or tab the window does not have; the error lists the valid names. |
| 4 | The process the verb needs is not running: the menu bar helper for `clean-keys`, `test-notification` and `open`, the main window for `quit`, `check-updates`, `reveal` and `snapshot`. Also `check-updates` when the app never answers within 60 seconds, and `relaunch` when no `Edith.app` can be found. |

3 comes only from `reveal`, and 1 only from `relaunch` and `snapshot`. The action
names are fixed rather than typed, so there is no name for you to get wrong:
`ed app frobnicate` is parsed as a stray argument to the default `actions`
subcommand and exits 2 rather than 3.

## Notes and gotchas

The transport is `DistributedNotificationCenter`, wrapped as `IPC`, with names
like `com.pulkit.edith.requestKeyboardClean`. Neither binary shells out to the
other and there is no socket, so a verb reaches Edith only when Edith is
listening for that exact name. `relaunch` is the exception: it posts a quit but
does not depend on anyone hearing it, terminating and starting the processes
itself.

"Running" means a process with that bundle id is registered with the window
server, which is what `NSRunningApplication` reports. An app in the middle of
launching reads as not running. `ed app relaunch` waits for the main app to
register before it returns, but the helper is started by the main app after
that, so `ed app relaunch && ed app clean-keys` still races the helper's launch.

Four of the seven actions are fire and forget: `ed` posts and returns without
waiting for confirmation, so exit 0 means the notification was sent.
`check-updates`, `reveal` and `snapshot` wait for a reply, and only they can
fail on silence. `ed app actions` is the way to check first rather than reading
exit codes after. `relaunch` is not one of the seven and is neither fire and
forget nor a reply: it watches the processes go and come back, so its exit code
says what actually happened.

Extensions gate two of the actions inside the app rather than in `ed`.
`clean-keys` needs the `system` extension and `test-notification` needs `usage`;
with the extension off, the helper is running, the guard passes, `ed` exits 0
and nothing happens. `ed extensions ls` is where that shows up.

`--json` output follows the CLI-wide contract: one document per invocation,
object keys sorted, absent values present as `null` rather than dropped.
`actions` and `updates` emit a top-level array, the rest an object. The one
document that drops keys rather than nulling them is the unanswered
`check-updates --no-wait`, which has no outcome to report and so carries
`requested` and `finished` alone. The `waiting for Edith to answer...` line from
`check-updates` goes to stderr, so piping stdout into `jq` stays clean.

The reply to `check-updates` also carries the check's `kind`, which `ed` does
not print; `ed app updates` shows the kind of every recorded check, and a check
you started with `ed` appears there as `automatic`, because the app runs the
request as a Sparkle background check rather than a user-initiated one.

The silence diagnosis for `check-updates` asks whether the menu bar helper is
running, while the guard before it asked about the main window. In the unusual
state where the window is open and the helper is not, the failure reads `Edith
is not running` rather than naming the helper.

`ed app clear-updates` writes nothing back to a running app. The window's own
history list is held in memory and is not told the file went, so it keeps
showing the old rows until the next check is recorded, at which point it
rewrites itself from the now-empty file and shows that one check.

`ed app quit` leaves the menu bar helper alive. `ed app relaunch` is the one verb
here that takes the helper down, and it does that by terminating the process
itself rather than asking Edith to; `RunningApps` still protects both Edith
bundle ids from every quit path it drives, `ed apps quit --all` included.

## Where to go next

- [`ed permissions`](../permissions/README.md) for the grants that make `ed app
  relaunch` worth running.
- [`ed extensions`](../extensions/README.md) for the `system` and `usage` switches that
  decide whether `clean-keys` and `test-notification` do anything.
- [`ed apps`](../apps/README.md) for quitting other applications, which is a different
  group with a similar name.
- [All command groups](../README.md).
