# `ed app`

`ed app` inspects and controls the Edith installation associated with this CLI.
The window, menu bar, core services, and downloaded extension engines run in one
app process. The production bundle identifier is `com.pulkit.edith`; development
builds have a separate identifier and data for each worktree.

Commands reach the matching app through its authenticated local command channel.
Use the CLI inside a development app to control that build. The `ed` on your
shell path normally reaches the installed application.

`quit`, `relaunch`, and `clear-updates` preview their effect until `--yes` is
present. JSON previews include `action`, `targets`, `applied`, `changed`, and
`requiresConfirmation`.

## At a glance

| Command | What it does |
| --- | --- |
| `ed app info` | Show app identity, version, build, and bundle path. |
| `ed app diagnostics` | Inspect the app process, core services, and active extensions. |
| `ed app paths` | List the installation's data and support folders. |
| `ed app links` | List repository, creator, extension guides, and contributor links. |
| `ed app open-path <id>` | Open or reveal one listed path. |
| `ed app open-link <id>` | Open one listed link. |
| `ed app actions` | List actions and their current availability; also `ed app ls`. |
| `ed app clean-keys` | Start keyboard cleaning through the System extension. |
| `ed app test-notification` | Send the app's test notification. |
| `ed app open` | Show the main window. |
| `ed app quit` | Close app windows, or quit the whole app with `--completely`. |
| `ed app check-updates` | Ask the app's updater to check for a release. |
| `ed app updates` | Print recorded update checks. |
| `ed app relaunch` | Restart this Edith installation. |
| `ed app clear-updates` | Clear recorded update history. |
| `ed app reveal` | Show a section and optional tab. |
| `ed app route` | Print the current window route. |
| `ed app navigate` | Change the route without bringing the app forward. |
| `ed app back` | Return to the previous route. |
| `ed app forward` | Advance through route history. |
| `ed app snapshot` | Save rendered open windows as PNG files. |

## Commands

- [`ed app info`](./info.md)
- [`ed app diagnostics`](./diagnostics.md)
- [`ed app paths`](./paths.md)
- [`ed app links`](./links.md)
- [`ed app open-path`](./open-path.md)
- [`ed app open-link`](./open-link.md)
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
- [`ed app route`](./route.md)
- [`ed app navigate`](./navigate.md)
- [`ed app back`](./back.md)
- [`ed app forward`](./forward.md)
- [`ed app snapshot`](./snapshot.md)

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The request completed or its preview was printed. |
| 1 | An action failed. |
| 2 | The command line was invalid. |
| 3 | A requested destination was not found. |
| 4 | The matching app or requested capability is unavailable. |

## Notes and gotchas

Closing windows leaves the same app process, menu bar, and enabled background
work running. `ed app quit --completely --yes` quits that process and its
extension engines. `ed app relaunch --yes` restarts the matching app so new
permission grants can take effect.

Availability depends on the installation and enabled extensions. Check
`ed app actions --json` and `ed extensions ls --json` before invoking an optional
feature. Development builds do not provide the production updater.

`--json` writes one document to stdout. Diagnostics and paths can contain local
paths or other personal information. Window snapshots capture the actual open
content, so use a separate build with synthetic data for shareable evidence.

## Where to go next

- [`ed permissions`](../permissions/README.md) for macOS grants.
- [`ed extensions`](../extensions/README.md) for downloads and enabled features.
- [`ed apps`](../apps/README.md) for controlling other applications.
- [All command groups](../README.md).
