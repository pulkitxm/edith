# `ed radial`

Shows the Radial Launcher or prints its active profile. The extension keeps one
profile with up to eight applications, files, links, key combinations, media
controls, and Edith actions.

```text
ed radial profile [--json]
ed radial show [--json]
```

A bare `ed radial` runs `profile`. Plain output prints the profile name and its
wheel order. JSON includes each item type, name, target, symbol, key code, and
modifier mask.

`ed radial show` asks the running menu bar helper to open the wheel at the
pointer. It exits 4 when the extension is off or Edith is not running.

The default shortcut is Option-Command-Space. Press it, point at a slice, and
release to run that action. A quick press leaves the wheel open for clicking,
number keys, arrows and Return. Escape closes it.

Key-combination slices need Accessibility permission. Other slice types and the
global shortcut do not.

- [`ed extensions`](../extensions/README.md)
- [`ed config`](../config/README.md)
- [All command groups](../README.md)
