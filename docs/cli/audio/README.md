# `ed audio`

`ed audio` inspects and changes this Mac's Core Audio devices, remembers a preferred
input, switches the system output, and saves output routes for individual applications.
A bare `ed audio` runs `ed audio status`.

Audio Controls in Edith Settings uses the same preferences and device operations. When
the extension is enabled, the helper keeps a preferred microphone selected while it is
available. It remembers the input that was active before the pin and restores it when the
extension is disabled, but only if Edith still owns the current selection.

The headphone safety option watches the default output. If headphones disappear and
macOS falls back to a non-headphone output, Edith lowers that output to the configured
safe percentage once. It restores the earlier level when headphones return or Audio
Controls stops, but only when the volume still equals the level Edith applied.

Per-app routes require macOS 14.4 or later and Application Audio access. They reuse the
Audio tab in Notch Shelf, including its per-app volume slider. A saved route stays active
while Audio Controls is enabled, even while the shelf is closed.

Music launch blocking is limited to Apple Music launches that immediately follow a play,
skip, or seek media key. Opening Music from the Dock, Spotlight, Finder, or a script is
left alone. When Edith's Music extension is enabled, the same media key starts its local
player after the unwanted Music launch is stopped.

## At a glance

| Command | What it does |
| --- | --- |
| `ed audio` | Runs `status`, the default subcommand. |
| `ed audio status` | Shows audio devices, current defaults, the preferred input, and saved app routes. |
| `ed audio input <device>` | Selects and pins an input by exact name or UID. Pass `system` to remove the pin. |
| `ed audio output <device>` | Switches the system and alert-sound output by exact name or UID. |
| `ed audio route <bundle-id> <device>` | Saves an application's output route. Pass `system` to remove it. |

## Commands

- [`ed audio status`](./status.md)
- [`ed audio input`](./input.md)
- [`ed audio output`](./output.md)
- [`ed audio route`](./route.md)

## Settings

| Key | Default | Purpose |
| --- | --- | --- |
| `audioControlsEnabled` | `false` | Runs preferred-input, safety, routing, and Music launch behavior. |
| `audioPreferredInputUID` | empty | The pinned input UID. Empty means follow the system default. |
| `audioLowerOnHeadphoneDisconnect` | `true` | Enables the one-time safe speaker reduction. |
| `audioSafeOutputPercent` | `25` | Safe output level from 0 to 50 percent. |
| `audioAppOutputRoutes` | empty map | Bundle identifier to output device UID routes. |
| `audioBlockMusicLaunch` | `false` | Blocks media-key-triggered Apple Music launches. |

Use `ed config get`, `set`, or `unset` for scripted preference changes. Device and route
commands apply immediately and notify a running helper.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The status was read or the requested change was applied. |
| 2 | A required argument or bundle identifier was invalid. |
| 3 | No matching device was found. |
| 4 | Core Audio could not enumerate or switch the requested device. |

## Where to go next

- [`ed permissions`](../permissions/README.md) covers Application Audio access.
- [`ed extensions`](../extensions/README.md) enables and verifies Audio Controls.
- [`ed config`](../config/README.md) reads and writes the underlying settings.
- [`ed music`](../music/README.md) controls Edith's reused local player.
- [All `ed` commands](../README.md)
