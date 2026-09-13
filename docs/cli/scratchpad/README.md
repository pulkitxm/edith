# `ed scratchpad`

`ed scratchpad` manages the same named pads as Edith's native floating Scratchpad panel. Pads are plain UTF-8 text, remain in tab order, and are saved atomically under Edith's application support directory. The CLI works while the app is closed, except `open`, which asks the running menu bar helper to show the panel.

## At a glance

| Command | What it does |
| --- | --- |
| `ed scratchpad` | Runs `ed scratchpad ls`. |
| `ed scratchpad ls` | Lists pads in tab order, with optional search. |
| `ed scratchpad show` | Prints one pad, or the selected pad when no name or id is passed. |
| `ed scratchpad create` | Creates and selects a named pad, optionally from text or a file. |
| `ed scratchpad set` | Replaces a pad's text from `--text`, a file, or stdin through `--file -`. |
| `ed scratchpad rename` | Renames a pad while preserving a unique display name. |
| `ed scratchpad duplicate` | Copies a pad into a newly selected tab. |
| `ed scratchpad rm` | Previews deleting a pad; `--yes` applies it. |
| `ed scratchpad clear` | Previews clearing a pad's text; `--yes` applies it. |
| `ed scratchpad copy-all` | Copies the exact text of one pad to the pasteboard. |
| `ed scratchpad export` | Writes one pad as exact UTF-8 text to a destination path. |
| `ed scratchpad open` | Toggles the native panel through the running helper. |
| `ed scratchpad remember` | Deliberately ingests one nonempty pad into Companion memory. |

Every command accepts `--json`. JSON output is one document on stdout. Mutating commands identify pads by UUID or by a case-insensitive exact name, announce `scratchpadChanged`, and leave diagnostics on stderr.

## Examples

```sh
ed extensions enable scratchpad
ed scratchpad create --name "Meeting" --text "# Decisions" --json
ed scratchpad set "Meeting" --file notes.md
ed scratchpad ls --search decision --json
ed scratchpad duplicate "Meeting"
ed scratchpad export "Meeting copy" ~/Desktop/meeting.md --json
ed scratchpad remember "Meeting" --json
ed scratchpad rm "Meeting copy" --yes --json
```

## Storage and clearing

The document is `scratchpad/pads.json` inside Edith's application support directory. Reads and writes take an advisory file lock, and writes replace the JSON document atomically. The helper debounces editor saves for half a second. CLI writes are immediate.

`scratchpadRetention` is `never`, `hour`, `day`, `week`, or `month`. Each nonempty pad tracks its most recent edit. The helper schedules the next expiry while it is running, and every CLI or panel load also clears pads whose quiet period has elapsed. Names and tab identity remain after text clears.

The Scratchpad configuration, including shortcut, retention, window behavior, and extension state, is included in Edith's settings backup. Pad content stays in the local document and can be moved explicitly with `export`.

## Window and permissions

The default global shortcut is `⌃⌥N`. Carbon hotkey registration does not need Accessibility, Input Monitoring, or another macOS privacy grant. `scratchpadAlwaysOnTop` controls whether the panel floats over normal windows. `scratchpadDismissOnDeactivate` controls whether it closes when another app becomes active.

Scratchpad has no Companion dependency. The Remember action is visible only when Companion is enabled, and it never runs implicitly. `ed scratchpad remember` exits unavailable when Companion is off or when the selected pad is empty.

## Where to go next

- [`ed extensions`](../extensions/README.md), to enable Scratchpad and inspect readiness
- [`ed config`](../config/README.md), for Scratchpad configuration
- [`ed companion`](../companion/README.md), for the optional memory destination
- [All `ed` commands](../README.md)
