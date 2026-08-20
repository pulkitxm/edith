# `ed extensions info`

Describes one extension without changing anything.

```
ed extensions info <id> [--json]
```

| Argument | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `id` | one of the fifteen ids, or a defaults key | required | The extension to describe |

| Option | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the indented block |

The human form is the title, the summary, then a fixed set of labelled rows. The
`needs` row appears only when the extension has required permissions and the
`asks for` row only when it has optional ones, so a plain extension prints four
rows:

```
$ ed extensions info clipboard
Clipboard
  Clipboard history with instant paste.
  id       clipboard
  key      clipboardEnabled
  group    Utilities
  state    on
  asks for Accessibility
```

```
$ ed extensions info calendar
Calendar
  Shows your schedule in the panel and the app.
  id       calendar
  key      tabCalendarEnabled
  group    Media
  state    off
  needs    Calendar
```

`needs` and `asks for` print the readable permission names (`Input Monitoring`,
`Screen Recording`), while `--json` prints the ids `ed permissions request`
accepts (`inputMonitoring`, `screenRecording`).

```json
{
  "enabled": false,
  "featured": false,
  "group": "Media",
  "id": "music",
  "key": "tabMusicEnabled",
  "missingRequiredPermissions": [],
  "optionalCapabilities": [
    "mediaControls"
  ],
  "optionalPermissions": [],
  "requiredCapabilities": [
    "localMusicPlayback"
  ],
  "requiredPermissions": [],
  "requiredTools": [
    "yt-dlp"
  ],
  "summary": "Plays your local music folder, with media keys.",
  "title": "Music"
}
```

```
ed extensions info notchShelf
ed extensions info music --json
ed extensions info tabMachinesEnabled
```

`info` is a pure read: no key is written and no notification is posted.
The human form does not print capabilities or required tools. Use `--json` when
you need those fields.

## Where to go next

- [`ed extensions`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
