# Keystroke Highlight

Keystroke Highlight puts a clear keycap on screen for every physical key press.
It is designed for product demos, tutorials, and screen recordings where the
viewer needs to follow keyboard input without watching the presenter’s hands.

Turn it on with:

```bash
ed extensions enable keystrokeHighlight
```

Input Monitoring is required. Edith uses a listen-only keyboard event monitor,
so the extension observes input without changing or blocking it. Secure keyboard
input is never shown.

## Display

Letters, numbers, symbols, navigation keys, and shortcuts appear as dark
rectangular keycaps. Modifiers are shown beside the key in macOS order. Recent
presses form a short centered row on the screen under the pointer, with at most
six visible at once.

Each key press disappears automatically. The default is 1.5 seconds, configurable
from 0.5 to 3 seconds:

```bash
ed config set keystrokeHighlightDuration 1.5
```

The overlay can sit at the top or bottom of the screen:

```bash
ed config set keystrokeHighlightPosition bottom
```

Changes apply to the running menu bar app immediately.

## Verify and recover

Check the complete lifecycle state:

```bash
ed extensions verify keystrokeHighlight --json
```

If the runtime is not ready, inspect its recovery guidance:

```bash
ed extensions doctor keystrokeHighlight --json
```

After granting Input Monitoring in System Settings, restart Edith if macOS has
not yet made the new grant available to the running process.
