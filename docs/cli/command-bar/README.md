# `ed command-bar`

`ed command-bar` uses the same local evaluator as Edith's Command Bar palette.
It is useful in scripts, terminals, and extension readiness checks because it
does not need the app or helper to be running.

## Commands

| Command | What it does |
| --- | --- |
| `ed command-bar calculate <expression>` | Evaluates arithmetic with parentheses, percentages, powers, and the usual operators. |
| `ed command-bar convert <value> <from> <to>` | Converts compatible length, mass, temperature, data, duration, or volume units. |

Both commands accept `--json`. Their JSON result includes `operation`, `kind`,
`formatted`, and numeric `value`. Conversion results also include `from` and
`to`.

```sh
ed command-bar calculate '(24 + 6) * 3'
ed command-bar calculate '200 + 15%' --json
ed command-bar convert 5 km mi
ed command-bar convert 72 fahrenheit celsius --json
```

## Palette

Enable the extension with `ed extensions enable commandBar`, then press
Option-Space. This default does not overlap Edith's Option-Command-E global
panel shortcut. The palette searches Edith destinations, actions exposed by
enabled extensions, installed applications, System Settings, emoji, and files
inside folders you choose. Clipboard results appear when Clipboard is enabled.
Selected-text actions appear when the front application exposes an editable
selection through Accessibility. Return runs the selected item. Command-Return
reveals a selected application or file in Finder.

Arithmetic and conversion answers appear above search results. Return copies an
answer. Application results also offer reveal, quit, and relaunch actions.
Control-click any result to pin or hide it. Stable results can be assigned one
of nine global Control-Option-number shortcuts.

Choose file search folders in Settings, Extensions, Command Bar. File results
use the metadata index maintained by macOS. Edith does not crawl those folders
or build a private index.

## Privacy and ranking

The optional ranking model stores only stable result identifiers, selection
counts, and last-used timestamps. It does not store query text, expressions, or
conversion inputs. Turn ranking off or clear it in Settings, Extensions,
Command Bar.

Installed application search reads app bundle metadata from the Applications
folders. It does not launch an app until you choose that result. Folder paths,
pinned and hidden result identifiers, and assigned shortcuts are saved in Edith
settings. Clipboard contents and selected text are not copied into ranking or
search state.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The expression or conversion succeeded. |
| 2 | The expression is invalid, a unit is unknown, units are incompatible, or arguments are missing. |

## Where to go next

- [`ed extensions`](../extensions/README.md), to enable and verify Command Bar
- [`ed config`](../config/README.md), for shortcut, application, and ranking settings
- [All `ed` commands](../README.md)
