# `ed windows`

`ed windows` controls the Window Switcher extension from the terminal. It lists
the same open and minimized windows shown in the switcher, opens the searchable
panel, activates one result, or cycles through the windows of the front app.

The menu bar app must be running, the extension must be enabled, and macOS must
grant Edith Accessibility access. The feature reads Accessibility window titles
and state. It does not capture the screen or create window previews.

## At a glance

| Command | What it does |
| --- | --- |
| `ed windows ls` | List switchable windows with app, title, state, process, and stable session id |
| `ed windows show` | Open the searchable Window Switcher panel |
| `ed windows activate <id>` | Restore and focus a window returned by `ls` |
| `ed windows cycle` | Focus the next window owned by the front application |

A bare `ed windows` runs `ls`. `window-switcher` is an alias for the command
group, and `list` is an alias for `ls`.

## Setup

```bash
ed extensions setup windowSwitcher
ed permissions request accessibility
ed permissions refresh
ed extensions verify windowSwitcher --json
```

The default shortcuts are Option-Tab for the searchable panel and Option-`
for cycling the front app. Both are configurable from the extension settings.

## Application rules

The switcher normally includes applications with a regular macOS activation
policy. `windowSwitcherIncludedApps` adds helper or accessory applications by
bundle identifier. `windowSwitcherHiddenApps` removes applications by bundle
identifier and takes priority over the include list.

```bash
ed config set windowSwitcherIncludedApps com.example.Utility
ed config set windowSwitcherHiddenApps com.example.Private,com.example.Chat
ed config set windowSwitcherGrouped false
```

## JSON

`ed windows ls --json` prints one array. Each object contains `id`, `app`,
`bundleIdentifier`, `title`, `minimized`, and `pid`. Window ids describe the
current Accessibility enumeration, so scripts should list immediately before
activating a result.

## Exit codes

| Code | When this group produces it |
| --- | --- |
| 0 | The operation completed |
| 2 | Arguments or the operation were invalid |
| 3 | The requested window id was not present |
| 4 | Edith is not running, the extension is off, Accessibility is missing, or no window can be cycled |

## Where to go next

- [`ed extensions`](../extensions/README.md), for enablement and readiness
- [`ed permissions`](../permissions/README.md), for Accessibility access
- [`ed config`](../config/README.md), for every Window Switcher setting
- [All command groups](../README.md)
