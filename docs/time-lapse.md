# Screen time-lapse

Enable Time-lapse in Extensions, then open it from the Media suite. Recording
requires macOS 15 or later and Screen Recording permission. Microphone access
is requested only when a microphone is selected.

Choose displays or windows, including multiple windows from different apps or
displays. Up to sixteen sources form a grid in a stable order. Windows are
captured independently, so overlapping windows do not cover each other. Refresh
sources after connecting a display or microphone or opening a new window.

Choose an interval from one to sixty seconds and a capture resolution up to
1080p, 4K, or the source resolution capped at 8K. Frames play at 30 fps. The
default five-second interval plays 150 times faster: five hours becomes two
minutes. The default video bitrate budget is about 180 MB for those five hours;
actual file size depends on the screen content and encoding overhead. Longer
intervals use less storage. The encoder writes sampled frames directly rather
than storing a full-speed video first.

System audio and the selected microphone are optional. They are recorded at
normal speed into separate AAC tracks, so speech remains usable. Each enabled
audio source adds about 58 MB per hour. System audio captures apps across the
desktop, including when the video source is a selection of windows. Audio is
exported separately and is not
synchronized to the accelerated video.

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
- Original capture joins segments without re-encoding, preserving the recording
  quality and exporting fastest.
- ProRes 422 exports a large editing master in a MOV file.

Higher export quality cannot restore detail that was not captured. Choose the
capture resolution before starting. Export system audio and microphone audio to
separate M4A files when needed. Show files opens the session's local folder.
