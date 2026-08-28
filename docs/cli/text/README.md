# `ed text`

Text Utilities adds reusable snippets, plain-text paste, automatic clipboard
clearing, and tracking-free links. The settings UI and `ed text` read the same
shared configuration, so changes made in either place take effect in the helper
without restarting Edith.

## Setup

```bash
ed extensions enable textUtilities
ed permissions request accessibility
ed permissions request inputMonitoring
ed extensions verify textUtilities --json
```

Accessibility lets Edith paste expansions and plain text into another app.
Input Monitoring lets it recognize snippet triggers as you type. URL cleaning
and the snippet CLI remain useful without those permissions.

Open Settings, Extensions, Text Utilities to configure every feature. The
runtime uses Edith's existing clipboard monitor, so enabling both Clipboard and
Text Utilities does not create a second polling loop.

## Commands

| Command | What it does |
| --- | --- |
| `ed text status` | Show extension settings and the saved snippet count |
| `ed text clean-url <url>` | Remove known tracking query parameters |
| `ed text paste-plain` | Ask the running helper to paste clipboard text without formatting |
| `ed text snippets ls` | List saved snippets |
| `ed text snippets add <trigger> <replacement>` | Add a snippet |
| `ed text snippets set <index>` | Change a snippet |
| `ed text snippets rm <index>` | Preview removing a snippet, then apply with `--yes` |

A bare `ed text` runs `ed text status`. A bare `ed text snippets` runs
`ed text snippets ls`. The list command also answers to `list`, and remove also
answers to `remove`.

## Clean links

```bash
ed text clean-url 'https://example.com/page?keep=1&utm_source=mail'
ed text clean-url 'https://example.com/?ref=share' --parameters ref
ed text clean-url 'https://youtu.be/example?si=token' --json
```

The cleaner removes common analytics parameters, every `utm_` parameter, and
service-specific share parameters for sites including YouTube, Spotify,
Instagram, Reddit, TikTok, X, Bilibili, and Xiaohongshu. It preserves the URL
scheme, host, path, useful query values, and fragment.

`--parameters` accepts a comma-separated list and overrides the custom list from
settings for that invocation. JSON output has this shape:

```json
{"changed":true,"removed":["utm_source"],"url":"https://example.com/page?keep=1"}
```

Automatic cleaning only rewrites clipboard items made entirely of text and URL
representations. Rich text, images, files, and other multi-format clipboard
payloads are left untouched.

## Paste without formatting

```bash
ed text paste-plain
ed text paste-plain --json
```

This command requires the Text Utilities extension and the Edith menu bar helper
to be running. Edith snapshots every pasteboard item and representation, writes
the plain string briefly, sends Command-V, and restores the snapshot only if no
other app changed the clipboard in the meantime. The default shortcut is
Control-Option-Command-V and can be recorded again in settings.

## Snippets

Create snippets with a trigger and replacement:

```bash
ed text snippets add ';sig' $'Thanks,\nPulkit' --name Signature --folder Work
ed text snippets add ';;today' '{{date}}' --mode immediate
ed text snippets add ';clip' '{{clipboard}}' --ignore-case --json
```

The default `after-delimiter` mode expands after a space, newline, or punctuation
character. `--mode immediate` expands as soon as the trigger is complete. Use
`--disabled` to save a snippet without making it active.

List and filter snippets:

```bash
ed text snippets ls
ed text snippets ls --folder Work
ed text snippets ls --search signature --json
```

Numbers are positions in the saved list. Change any subset of fields with
`ed text snippets set`:

```bash
ed text snippets set 1 --name 'Work signature' --folder Work
ed text snippets set 1 --replacement 'Thank you' --ignore-case true
ed text snippets set 1 --mode immediate --enabled false --json
```

Removal uses the standard destructive preview contract:

```bash
ed text snippets rm 1
ed text snippets rm 1 --yes --json
```

The first command changes nothing and prints the exact target. The second saves
the new list and notifies a running helper immediately.

## Variables

Snippet replacements can contain these values:

| Variable | Result |
| --- | --- |
| `{{date}}` | Current date as `yyyy-MM-dd` |
| `{{time}}` | Current time as `HH:mm` |
| `{{datetime}}` | Current local date and time |
| `{{clipboard}}` | Current clipboard text, or an empty string |
| `{{date:MMM d}}` | Current date using a custom Unicode date format |
| `{{time:h:mm a}}` | Current time using a custom Unicode date format |

Variables are resolved when the snippet expands, not when it is saved.

## Clipboard privacy

Settings can clear an unchanged clipboard after 5 to 3,600 seconds, when the
screen locks, or before the Mac sleeps. A delayed clear remembers the exact
pasteboard generation it observed. If you copy something newer before the
deadline, the older timer cannot erase it.

The clipboard history is independent. If both extensions are enabled, the same
clipboard observation captures history, cleans eligible links, and manages the
privacy deadline. Turning Clipboard off stops history capture while Text
Utilities continues to clean and clear copied content.

## Configuration

The full settings group is available through the normal config commands:

```bash
ed config ls --group text --json
ed config set textUtilitiesCleanCopiedURLs true
ed config set textUtilitiesAutoClearDelay 60
ed config set textUtilitiesClearOnLock true
```

Snippet JSON is managed most safely with `ed text snippets`. The config surface
still exposes it so exports, imports, and settings backup remain complete.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The command completed, including an empty list or a removal preview |
| 2 | Invalid URL, mode, index syntax, empty value, duplicate trigger, or missing update options |
| 3 | No snippet exists at the requested number |
| 4 | Plain-text paste cannot reach an enabled running helper |

[All `ed` commands](../README.md)
