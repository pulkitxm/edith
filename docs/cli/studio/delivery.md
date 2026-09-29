# Native project delivery

[Back to the CLI reference](../README.md) · [Studio](./README.md)

`ed studio edit render`, `ed studio edit render-audio` and `ed studio edit frame`
deliver an existing `.openscreen` project through the native editor pipeline.
They run locally without opening the app. Settings are explicit command flags;
they are separate from the edit-plan JSON schema.

## `ed studio edit render`

```sh
ed studio edit render demo.openscreen --output delivery.mp4 --json
ed studio edit render demo.openscreen --output master.mov --codec proRes422HQ \
  --color-space displayP3 --progress --json
```

The composition supplies the canvas, frame cadence and output duration after
speed and trim edits. Choose these encoding settings:

| Flag | Values and default |
| --- | --- |
| `--codec` | `h264` (default), `hevc`, `hevc10`, `proRes422`, `proRes422HQ`, `proRes4444` |
| `--bit-rate` | Video bits/second, 100000 to 1000000000; default 40000000; unused for ProRes |
| `--key-frame-interval` | Maximum frames between keyframes, 1 to 10000; default 120; unused for ProRes |
| `--audio-codec` | `aac` or `pcm`; default PCM for ProRes, AAC otherwise; PCM requires ProRes |
| `--audio-bit-rate` | AAC bits/second, 32000 to 320000; default 320000; mono maximum 256000 |
| `--audio-sample-rate` | 44100, 48000 (default), or 96000; 96000 requires PCM |
| `--audio-channels` | 1 or 2 (default) |
| `--color-space` | `rec709` or `displayP3`; default project/composition color, then Rec.709 |
| `--require-hardware` | Require hardware encoding; supported for H.264 and HEVC |

H.264 and HEVC require a `.mp4` destination. ProRes requires `.mov`.
HEVC Main 10 and ProRes retain high-precision rendering buffers. The selected
color space controls both the reader composition and writer color tags.

## `ed studio edit render-audio`

```sh
ed studio edit render-audio demo.openscreen --output mix.wav --json
ed studio edit render-audio demo.openscreen --output mix.aiff --container aiff \
  --sample-rate 96000 --channels 2 --progress --json
ed studio edit render-audio demo.openscreen --output mix.m4a --container m4a \
  --channels 1 --bit-rate 192000 --json
```

| Flag | Values and default |
| --- | --- |
| `--container` | `wav` (default), `aiff`, or `m4a`; the output extension must match |
| `--sample-rate` | Samples/second: 44100, 48000 (default), or 96000; M4A excludes 96000 |
| `--channels` | 1 or 2 (default) |
| `--bit-rate` | AAC bits/second, 32000 to 320000; default 320000; mono maximum 256000 |

WAV and AIFF use 24-bit PCM. M4A uses AAC. The native mix retains leading silence,
gaps and the timeline tail, with a measured audio sample-frame count.

## `ed studio edit frame`

```sh
ed studio edit frame demo.openscreen --frame 15 --output frame.png --json
ed studio edit frame demo.openscreen --time 0.25 --output preview.png --json
```

Supply exactly one of `--frame INDEX` or `--time SECONDS`. Frame indices are
zero-based rendered output frames, evaluated with the exact rational composition
cadence. A time selects the preceding output frame, using the same selection
rules as contact sheets. The selected frame must be inside the composition.
Result JSON adds `frame` and `time`, with time expressed in output seconds.

## Output, reports and cancellation

All three commands require `--output PATH`. Create the destination directory
first. Existing files require `--overwrite`. Source media, project dependencies,
symlinks and directories cannot be replaced. Publication is atomic, so failed
or cancelled delivery preserves an existing destination and removes partial files.

`--json` returns one final stdout document with `version`, `path`, `written`,
`clipIDs` and `aliases`. Video delivery adds `videoReport`: dimensions, duration
in seconds, frame count, rational frame rate, measured bitrate, video/audio codecs,
color tags, bit depth, audio sample rate/channels, bytes and SHA-256. Audio delivery
adds `audioReport`: codec, optional bits per sample, duration in seconds, sample
rate in Hz, channels, sample `frames`, bytes and SHA-256. Unavailable optional
measurements are omitted.

Both delivery commands support `--progress`. It emits at most 101 increasing
updates to stderr, never stdout. With `--json`, updates are JSON lines such as
`{"version":1,"event":"progress","percent":42}`; otherwise they are readable text.
100 means the completed output has been published. A runtime failure is the final
stderr error object. SIGINT and SIGTERM cooperatively cancel native delivery,
return error code `cancelled`, and exit 130 or 143 respectively.

The MCP tools `edith_studio_edit_render`, `edith_studio_edit_render_audio` and
`edith_studio_edit_frame` accept the same flags in their `arguments` array.
Video and audio delivery have a six-hour MCP execution limit. MCP returns the
final report; child stderr progress does not alter the result JSON.
