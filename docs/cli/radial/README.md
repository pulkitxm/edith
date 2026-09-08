# Radial Launcher

Radial Launcher puts a configurable wheel around the pointer so frequently used
actions stay one gesture away. Its active profile holds up to eight actions in
a stable clockwise order.

## Set up the wheel

Enable Radial Launcher from Settings > Extensions, then open its settings. The
starter profile demonstrates every supported action type. Each action can be
edited, duplicated, reordered, or removed, and incomplete actions stay out of
the runtime wheel until their target is valid.

| Action | Target |
| --- | --- |
| Application | A macOS application selected from disk |
| File or folder | Any local file or directory |
| Link | An `http` or `https` URL |
| Key combination | A recorded shortcut with one or more modifiers |
| Media control | Play or pause, next track, or previous track |
| Edith action | Open Edith, Clipboard, Color Picker, Mic Mute, or Clean Keys |

The default shortcut is Option-Command-Space. It can be changed in the
extension settings or the Shortcuts pane. Center on pointer can be turned off
to place the wheel in the middle of the active display instead.

## Use the wheel

Press the global shortcut, move toward a slice, and release to execute it. A
quick press without a direction leaves the wheel open. While it is open, you
can click a slice, press its number, use arrow keys and Return, or press Escape
to close it. Clicking outside also closes the wheel.

The wheel is clamped to the visible part of the current display, so it remains
usable near screen edges and across multiple displays.

## Command line

The CLI shows the same active profile and can summon the same helper runtime.

```text
ed radial profile [--json]
ed radial show [--json]
```

A bare `ed radial` runs `profile`. Plain output prints the profile name and its
wheel order. JSON includes each item type, name, target, symbol, key code,
modifier mask, and whether the item is fully configured.

`ed radial show` asks the running menu bar helper to open the wheel at the
pointer. It exits 4 when the extension is off or Edith is not running.

Use the configuration catalog to inspect the extension without opening Edith:

```text
ed config ls --group radial
ed extensions status radialLauncher
ed extensions doctor radialLauncher --json
```

## Permissions and recovery

Key-combination slices need Accessibility permission. Other slice types and the
global shortcut do not. If a key combination beeps instead of running, grant
Accessibility in System Settings and run `ed permissions refresh`.

If the shortcut does not open the wheel, check that Radial Launcher is enabled
and Edith is running. A shortcut already owned by another app must be changed in
settings. `ed extensions doctor radialLauncher --json` distinguishes a stopped
helper, an invalid shortcut or profile, and a profile with no complete actions.

- [`ed extensions`](../extensions/README.md)
- [`ed config`](../config/README.md)
- [All command groups](../README.md)
