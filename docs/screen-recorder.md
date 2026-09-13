# Screen Recorder

Screen Recorder is part of Capture Studio. It records a selected area, a
window, or a full display with ScreenCaptureKit. The picker and recording
controls belong to Edith, so display and area recordings exclude them from the
captured output.

## Recording

Open Capture Tools in Settings or the menu bar, then choose Record area,
Record window, or Record display. The Capture Tools shortcut starts an area
recording when idle and stops the active recording. The floating controls can
pause, resume, stop, or cancel.

System audio and microphone input are optional. When both are enabled, the
untouched take keeps them on separate tracks. The editor provides an
independent volume control for each source. Microphone capture uses the current
default input and requires Microphone permission.

Stopping closes the stream before finalizing the writer. Cancelling discards
the active take. A take uses a fragmented MOV while recording, with its
metadata, pointer samples, and edit document in a private Capture Studio
folder. This lets Recent Recordings recover a usable interrupted take after a
crash. Finished and recovered takes are bounded to eight items and 2 GB.

## Editing and export

The native editor keeps the master unchanged. Its edit document stores:

- trim handles and any number of cuts
- pointer visibility, smoothing, size, and click markers
- optional automatic click zooms
- timed text overlays
- crop, background colour, and padding
- separate system audio and microphone gains
- reusable export presets for format, width, frame rate, and quality

MP4 export keeps audio and applies the edit document through an AVFoundation
composition. GIF export uses the same visual composition, omits audio, and is
limited to 30 seconds to keep memory bounded. A finished export can be copied
as a file, dragged from the editor, or revealed in Finder.

## Command line

`ed capture record area`, `window`, and `display` use the same interactive
native routes as the app. `pause`, `resume`, `stop`, `cancel`, and `library`
control those routes without accepting arbitrary paths. `status --json` reads
the shared lifecycle state without opening a window.

See [`ed capture record`](cli/capture/record.md) for the complete command and
JSON contracts.

## Privacy and storage

Screen and audio samples stay on this Mac. Capture Studio never uploads a take.
Settings backup includes recording options, shortcuts, and export presets. It
does not include recordings or live lifecycle state.

## Component provenance

The recorder lifecycle, pause clock, recovery policy, pointer smoothing,
timeline, and export composition were adapted from the GPL-3.0-or-later
recorder components in
[`vorssaint-utils`](https://github.com/vorssaintapp/vorssaint-utils) at commit
`4c65c76cda0554625c726e6bb0fc9e97166effe1`. No external artwork or product
branding is included. Edith is distributed under the GPL-3.0.
