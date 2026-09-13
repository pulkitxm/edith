# `ed capture`

`ed capture` starts Edith's local Capture Studio tools. Capture an area, a
window, or the full main display, reopen recent captures, or recognize screen
text and codes without sending the image anywhere.

Recognition uses macOS Vision on this Mac. QR, Micro QR, Aztec, Data Matrix,
PDF417, Code 39, Code 93, Code 128, EAN, UPC-E, and ITF-14 payloads take
priority over OCR text. The quick preview can copy or drag a PNG, save, edit,
pin, delete, copy recognition results, and open a single strict HTTP or HTTPS
code.

The recent-captures library keeps up to 12 PNGs with a 256 MB bound. Its cards
copy, save, drag, edit, pin, or delete a capture. The editor provides crop,
pen, arrow, rectangle, ellipse, text, redaction, and optional background
framing. All work remains local.

## Commands

| Command | What it does |
| --- | --- |
| `ed capture read` | Selects screen content, recognizes text and codes, and copies the configured result. |
| `ed capture area` | Captures a selected area and opens the quick preview. |
| `ed capture window` | Captures a selected window and opens the quick preview. |
| `ed capture screen` | Captures the full main display and opens the quick preview. |
| `ed capture library` | Opens the recent-captures library. |

Bare `ed capture` runs `ed capture read`.

- [`ed capture read`](./read.md)
- [`ed capture area`](./area.md)
- [`ed capture window`](./window.md)
- [`ed capture screen`](./screen.md)
- [`ed capture library`](./library.md)

Every command requires the Capture Tools extension and the running menu bar
app. Capture commands also require Screen Recording permission. They return
after sending the request, and interactive selection finishes asynchronously.

## Privacy and related tools

Images and recognition results stay on this Mac. Screenshots remain in the
bounded local library until deleted or pruned. Saved images use
`captureSaveFolder` and `captureFilenameTemplate`, with
`~/Pictures/Edith Captures` as the default folder. Screen-read images remain
temporary unless `captureSaveScreenshots` is enabled.

Capture Tools does not duplicate Edith's other camera features. Use Color
Picker for exact screen colors and Notch Shelf for its camera mirror preview.

## Where to go next

- [`ed permissions`](../permissions/README.md), for Screen Recording access
- [`ed config`](../config/README.md), for the `capture` settings group
- [`ed color`](../color/README.md), for exact pixel colors
- [All `ed` commands](../README.md)
