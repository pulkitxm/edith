# Validated AAC packet-copy delivery

Native video rendering can preserve a previously approved AAC soundtrack's
compressed packets without decoding or re-encoding that soundtrack:

```sh
ed studio edit render demo.openscreen --output delivery.mp4 \
  --audio-codec copy --audio-copy-track AUDIO_TRACK_ID \
  --audio-sample-rate 48000 --audio-channels 2 --json
```

H.264 and HEVC use MP4; ProRes uses MOV. The same flags are available through
`edith_studio_edit_render`. The selected independent track's processed audio
reference takes precedence over its original source. Its source may be an
audio-only file or a video container, but must contain exactly one AAC stream.
FFmpeg and ffprobe must be available through Studio engine detection.

Preflight runs before creating delivery files. Copy requires:

- Exactly one audible independent track, explicitly selected by ID.
- Any attached clip audio muted or absent.
- Source offset zero and output start zero, unity rate/gain, no loop, fades,
  gain envelope, audio joins, or other audible tracks.
- Complete source-stream duration matching both soundtrack and video timing.
- Matching sample rate and channel options, with no resampling or downmix.
- No `--start-frame` or `--end-frame` selection. Partial stream copies are
  currently rejected, even if a requested cut might align to a packet.

The full AAC stream need not have a duration divisible by 1024 samples. Encoder
priming, final partial packet durations, skip-sample records, and trailing
padding are supported and preserved. Full-stream copy is distinct from cutting
a partial AAC packet. Ambiguous timestamps, gaps, overlapping packets, missing
codec configuration, multiple audio streams and unaccounted preroll are rejected.

Video is rendered through the existing native pipeline into temporary video-only
media. FFmpeg then remuxes that native video with the approved soundtrack using
stream copy. A shared rational movie timescale preserves source sample timing.
Before atomic publication, ffprobe compares every packet's SHA-256, PTS, DTS,
duration and skip/padding metadata, plus codec configuration, sample rate,
channels, timebase and presentation bounds. Native verification also checks the
video frame count and canvas. The final report includes `audioPassthrough` with
the source hash, packet count, timebase and `packetDataAndTimingVerified: true`.

There is no silent encoding fallback. Unsupported requests return
`invalid_audio_copy`; backend and verification failures have separate error
codes. The normal source/project destination protections and atomic overwrite
rules also apply. Audio bitrate is unused for packet copy.
