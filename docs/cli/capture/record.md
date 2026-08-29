# `ed capture record`

Controls Capture Studio's Screen Recorder through safe native routes.

Usage:

```text
ed capture record area [--json]
ed capture record window [--json]
ed capture record display [--json]
ed capture record pause [--json]
ed capture record resume [--json]
ed capture record stop [--json]
ed capture record cancel [--json]
ed capture record status [--json]
ed capture record library [--json]
```

| Command | What it does |
| --- | --- |
| `ed capture record area` | Opens the area selector and begins recording after confirmation. |
| `ed capture record window` | Opens the window chooser and begins recording the selected window. |
| `ed capture record display` | Opens the display chooser and begins recording the selected display. |
| `ed capture record pause` | Pauses the active take and removes the pause from its final timeline. |
| `ed capture record resume` | Resumes a paused take. |
| `ed capture record stop` | Finalizes the take and opens the native editor. |
| `ed capture record cancel` | Safely closes the stream and discards the active take. |
| `ed capture record status` | Reads shared lifecycle state without opening a native surface. |
| `ed capture record library` | Opens recent and recovered recordings. |

Bare `ed capture record` runs `ed capture record area`.

The interactive commands return after Edith accepts the request. With
`--json`, their acknowledgement is shaped like:

```json
{"interactive":true,"operation":"capture.record.area","requested":true}
```

Status JSON includes stable lifecycle fields and the active source or take when
available:

```json
{"elapsedSeconds":12.4,"source":"area","state":"recording","takeId":"0645BE3C-0D9E-4275-A39C-62575116394A"}
```

The Capture Tools extension and running menu bar app are required for every
interactive route. Screen Recording permission is required to start. Enabling
microphone audio also requires Microphone permission.

## Where to go next

- [`ed capture`](./README.md)
- [`ed permissions`](../permissions/README.md)
- [`ed config`](../config/README.md)
- [All `ed` commands](../README.md)
