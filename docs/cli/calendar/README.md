# `ed calendar`

Your schedule, as the Edith app sees it. The calendar grant belongs to the Edith
bundle rather than to this binary, so `ed` never reads EventKit itself: it asks
the running menu bar app for the events it holds and prints them. Reach
for it when you want the next few days on stdout, or as JSON for something else
to read.

The group has one verb. If the app is closed, the Calendar extension is off, or
macOS has not granted calendar access, it exits 4 and says which of the three it
was.

## At a glance

| Command | What it does |
| --- | --- |
| `ed calendar` | No subcommand runs `ls`, so a bare `ed calendar` is the upcoming events |
| `ed calendar ls` | Upcoming events from the running app, as a table or as JSON |

`ed calendar list` is an alias for `ed calendar ls`.

## Commands

## Commands

- [`ed calendar ls`](./ls.md)

## Exit codes

| Code | When |
| --- | --- |
| 0 | Events were printed, including the case where the window holds none |
| 2 | `--days` was negative (written as `--days=-1`), `--days` was given no value or a value that is not an integer, or the command line carried an unknown flag |
| 4 | The menu bar app is not running, the Calendar extension is off, macOS has not granted calendar access, or the app did not answer within 4 seconds |

Exit 3 has no producer here; `ed calendar` names nothing that can be missing.

## Notes and gotchas

- The app decides the window, not `ed`. The store loads from midnight today
  through 14 days ahead, and `ed` filters that list down to `--days`. Asking for
  more than the app has loaded returns what it has rather than failing, so
  `ed calendar ls --days 30` usually shows the same 14 days as `--days 14`.
- The only thing that widens the app's window is scrolling to the bottom of a
  calendar list in the UI, which loads another 14 days at a time up to 120. `ed`
  cannot ask for more, and the window resets to 14 days whenever the app or the
  extension restarts.
- Because the window starts at midnight rather than now, events that already
  started today are included. `--days 0` therefore means "everything from today
  that has already started", not "today's schedule", and it is usually the wrong
  flag to reach for.
- Ordering is fixed: all-day events first, then everything else by start time
  ascending. The JSON array uses the same order as the table.
- Duplicates are collapsed before they are sent. Two events with the same title,
  start, end and all-day flag count as one, which is what removes the twin rows
  when the same invitation lands in two calendars. The surviving row keeps
  whichever calendar EventKit listed first.
- A meeting link is detected, not stored. `ed` shows the event's own URL when it
  points at a known conferencing host, and otherwise the first such link found
  in the location and notes. The hosts are `zoom.us`, `meet.google.com`,
  `teams.microsoft.com`, `teams.live.com`, `webex.com`, `whereby.com`,
  `meet.jit.si`, `chime.aws`, `gotomeeting.com`, `bluejeans.com` and `8x8.vc`,
  including their subdomains. A link to anything else is left in `location` and
  `meetingURL` stays `null`.
- Times are transported and printed as two different things. `--json` gives
  ISO 8601 in UTC; the table renders in the local time zone with localised day
  and month names, so the two can look like different days near midnight.
- Filtering happens in `ed`, after the whole list has arrived, so a small
  `--days` does not make the request cheaper. The cost is one round trip either
  way.
- The extension switch is a setting like any other:
  `ed config set tabCalendarEnabled true` and `ed extensions enable calendar`
  write the same key. Enabling the extension without the macOS grant leaves
  `ed calendar ls` exiting 4 on the permission, so request it as well.
- Turning the extension on creates the store inside the running app, and a store
  with no grant never populates. After granting calendar access, `ed app
  relaunch` is the reliable way to make the app pick the new state up.

## Where to go next

- [`ed extensions`](../extensions/README.md) to turn the Calendar extension on or off
- [`ed permissions`](../permissions/README.md) to request the macOS calendar grant
- [`ed config`](../config/README.md) for `tabCalendarEnabled`, the only key in the
  `calendar` group
- [`ed app`](../app/README.md) for `ed app relaunch`, which a new grant needs
- [All command groups](../README.md)
