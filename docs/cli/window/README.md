# Window Tools

Window Tools arranges the active window with global shortcuts, settings controls,
or `ed window` commands. It can also make the green window button fill the usable
display without creating another Space.

## Setup

```bash
ed extensions enable windowTools
ed permissions request accessibility
```

The extension stays inactive until Accessibility is granted in System Settings.
Edith only reads the active window and changes its position and size when you run
an action or click its green button.

## Commands

```bash
ed window status
ed window left-half
ed window right-half
ed window top-half
ed window bottom-half
ed window top-left
ed window top-right
ed window bottom-left
ed window bottom-right
ed window center
ed window maximize
ed window next-display
ed window restore
```

Every action accepts `--json`. Run `ed window --help` for the complete list.
Restore steps back to the frame captured before the most recent placement for
that window. `ed window status --json` reports whether the extension, helper,
and Accessibility grant make actions available.

[Capture and restore workspace profiles](./workspaces.md)

## Settings

Open Settings, Extensions, Window Tools to change the left-half, right-half,
maximize, and restore shortcuts. The green-button override can be disabled while
keeping layouts and shortcuts available.

## Scope

Edith already handles Dock reopen and quit-on-last-window for its own application.
Window Tools does not change the lifecycle of other applications. Its runtime is
limited to explicit window arrangement and the optional green-button override.

[All `ed` commands](../README.md)
