# `ed capture`

`ed capture` starts Edith's offline screen-reading and quick screenshot tools.
Both commands use the standard macOS selector, so you can drag a region or
choose a window without learning a separate capture interface.

Recognition uses macOS Vision on this Mac. QR, Micro QR, Aztec, Data Matrix,
and PDF417 payloads take priority over OCR text. Edith copies the configured
result after a screen read, keeps a bounded recent-read history, and shows a
transient preview with Copy image, Save, Copy result, and Discard actions. A
single strict HTTP or HTTPS code also gets an explicit Open action.

The first capture requests Screen Recording access when it is missing. Recent
reads can be copied again or cleared from Capture Tools settings.

## Commands

| Command | What it does |
| --- | --- |
| `ed capture read` | Selects screen content, recognizes text and codes, and copies the configured result. |
| `ed capture screenshot` | Selects screen content and opens the lightweight screenshot preview. |

- [`ed capture read`](./read.md)
- [`ed capture screenshot`](./screenshot.md)

Both commands require the Capture Tools extension, the running menu bar app,
and Screen Recording permission. They return after sending the request. The
desktop selection and recognition finish asynchronously.

## Privacy and related tools

Images and recognition results stay on this Mac. A selected image is temporary
unless you click Save or enable `captureSaveScreenshots`. Saved images go to
`~/Pictures/Edith Captures`.

Capture Tools does not duplicate Edith's other camera features. Use Color
Picker for exact screen colors and Notch Shelf for its camera mirror preview.

## Where to go next

- [`ed permissions`](../permissions/README.md), for Screen Recording access
- [`ed config`](../config/README.md), for the `capture` settings group
- [`ed color`](../color/README.md), for exact pixel colors
- [All `ed` commands](../README.md)
