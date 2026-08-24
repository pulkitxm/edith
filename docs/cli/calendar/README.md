# `ed calendar`

Your schedule, as the Edith app sees it. The calendar grant belongs to the Edith
bundle rather than to this binary, so `ed` never reads EventKit itself: it asks
the running menu bar app for the events it holds and prints them. Reach
for it when you want the next few days on stdout, or as JSON for something else
to read.

The agenda and join commands need the running app. If the app is closed, the Calendar extension is off, or
macOS has not granted calendar access, it exits 4 and says which of the three it
was.

## At a glance

| Command | What it does |
| --- | --- |
| `ed calendar` | No subcommand runs `ls`, so a bare `ed calendar` is the upcoming events |
| `ed calendar ls` | Upcoming events from the running app, as a table or as JSON |
| `ed calendar open` | Opens the Calendar application |
| `ed calendar join <event>` | Opens the meeting link for an event ID or unambiguous title |
| `ed calendar directions <event>` | Opens the event location in Maps |

`ed calendar list` is an alias for `ed calendar ls`.

## Commands

- [`ed calendar ls`](./ls.md)
- [`ed calendar open`](./open.md)
- [`ed calendar join`](./join.md)
- [`ed calendar directions`](./directions.md)

## Exit codes

| Code | When |
| --- | --- |
| 0 | Events were printed, including the case where the window holds none |
| 2 | `--days` was outside 0 through 120, had no value or was not an integer, or the command line carried an unknown flag |
| 3 | `join` or `directions` could not find one unambiguous event |
| 4 | The menu bar app is not running, the Calendar extension is off, macOS has not granted calendar access, or the app did not answer within 4 seconds |

## Notes and gotchas

- The request carries its exact date window to the app. `--days` accepts 0 through
  120, matching the UI's upper bound. A larger value exits 2 before the app is
  contacted.
- The UI starts at 14 days and scrolling to the bottom adds 14 days at a time. The
  last page adds 8 days and stops at 120. A CLI read does not change the UI's
  current page.
- Every window starts at midnight today. A positive value ends at midnight that
  many days later. `--days 0` ends at the moment the command starts, so it includes
  events from earlier today.
- `join` and `directions` search the full 120-day window. An ID returned by
  `ed calendar ls --days 120 --json` can therefore be used by either action.
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
- Filtering, sorting and deduplication use the same typed operation as the UI.
  The app reads only the requested window, and the cost is one round trip.
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
