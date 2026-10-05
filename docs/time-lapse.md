# Screen Recorder

Enable Screen Recorder in Extensions, then open it from the Media suite. Recording
requires macOS 15 or later and Screen Recording permission. Microphone access
is requested only when a microphone is selected.

Open Source to choose displays or windows from a visual thumbnail grid. Select
multiple cards, search by app or window name, and confirm with Use selection.
Cancel keeps the previous selection. Thumbnails are small, one-shot previews
loaded while browsing, and sources with unavailable previews remain selectable.
Expand Audio & options to select audio, the cursor,
and whether to keep the Mac awake. Up to sixteen sources form a grid in a stable order. Windows are
captured independently, so overlapping windows do not cover each other. Refresh
sources after connecting a display or microphone or opening a new window.

Standard is the default recording mode. Choose 30 or 60 fps, a source and capture
quality, then click Record. Click Stop recording when finished and export from
Recordings. The video plays at normal speed, with system audio and the selected
microphone synchronized and included in the export. When both audio sources are
selected, they are mixed into one soundtrack. Standard recording uses more space
than time-lapse, and shows its own hourly storage estimate.

Choose Time-lapse mode for a compact accelerated recording. Choose a time-lapse speed from 30× to 1800× and a capture resolution up to
1080p, 4K, or the source resolution capped at 8K. The estimate shows how one hour
becomes a shorter video. Frames play at 30 fps. The
default 150× speed makes five hours become two
minutes. The default video bitrate budget is about 180 MB for those five hours;
actual file size depends on the screen content and encoding overhead. Faster
speeds use less storage. The encoder writes sampled frames directly rather
than storing a full-speed video first.

The recorder fills the window width, scales the preview to the available space,
and stacks controls in narrower windows. Record and Stop remain above the preview.
While recording, the preview shows the last captured frame and updates at the
chosen speed in Time-lapse, or up to ten times per second in Standard. Elapsed time, playback length, saved size, and Stop stay visible
below it. The first frame appears as soon as the selected sources are ready.

System audio and the selected microphone are optional. Every export produces one
video containing the selected audio. Standard keeps audio synchronized at normal
speed. Time-lapse accelerates the audio by the chosen speed while preserving its pitch.
When both sources are selected, they are mixed into one soundtrack. System audio
captures apps across the desktop, including when recording selected windows.
Audio is stored internally at normal speed for export, adding about 58 MB per
hour for each selected source. There is no separate audio export.

Keep Mac and screen awake prevents idle system and display sleep while recording,
at the cost of power. Recording continues when leaving the page or closing its
window. Sleeping, blank or unavailable sources are skipped, with no burst of
catch-up frames. Quitting Edith finalizes the active recording before exit. A
disconnected source or full drive stops recording;
512 MB is reserved for finalization. No recorder can store unlimited days in a
fixed amount of space, so watch the storage estimate for long recordings.

Video is saved in HEVC segments of at most five minutes of real time. The session
manifest is updated atomically when each segment finishes, and completed segments
survive interruptions. An
interrupted session can export completed segments; the unfinished segment may be
lost. The library keeps the original segments after export.

After stopping, select a session and an export quality:

- Compact HEVC exports up to 1080p.
- High quality HEVC exports at the recorded resolution.
- Original capture preserves the encoded video without re-encoding. Audio is
  mixed and accelerated as needed.
- ProRes 422 exports a large editing master in a MOV file.

Higher export quality cannot restore detail that was not captured. Choose the
capture resolution before starting. Click Export video and choose a destination. The saved MP4 or MOV includes audio;
internal recording segments remain in the local library.
