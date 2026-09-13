# `ed dock`

`ed dock` reports Dock Tools readiness and controls the preview surface from the shell.

```sh
ed dock status
ed dock status --json
ed dock windows com.apple.Safari --json
ed dock show com.apple.Safari
```

Dock Tools requires Accessibility to identify Dock icons and focus app windows. Screen
Recording is optional and adds live window thumbnails. Without it, previews remain useful
with app icons and window titles.

The extension supports hover previews or deliberate Option-click activation. Clicking the
active app can retain standard macOS behavior, cycle through that app's windows, or minimize
its front window. The green window button and quit-on-last-window policies are opt-in.

Per-app exclusions use bundle identifiers and apply to every Dock Tools behavior. Configure
them in the extension settings or with `ed config set dockToolsExcludedApps`.

Use `ed extensions enable dockTools` to turn the extension on and `ed permissions refresh`
after changing macOS Privacy & Security settings.

- [`ed`](../README.md), the complete command line reference
