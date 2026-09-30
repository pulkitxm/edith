# Full-quality delivery

## Decide what the file must be

Resolve the target before encoding:

| Property | Decision |
| --- | --- |
| Geometry | Width, height, aspect ratio, crop or padding intent |
| Time | Exact rational rate, expected frame count or duration |
| Video | Container, codec, quality or bitrate, color requirements |
| Audio | Required tracks, channels, sample rate, gain or loudness intent |
| Handoff | Master, review copy, editable project and media dependencies |

Use original visual media, not a previous review encode, as the source for the master.
Native project operations preserve the ability to revise an edit without another
generation of lossy intermediates. A full-quality delivery means meeting the
agreed output properties; it does not mean a lossy export is mathematically
identical to its original.

## Map requirements to supported controls

Read `ed studio edit render --help` and the current plan schema. Project settings
and render flags serve different purposes: establish canvas and timing through
the supported project interface, then select delivery controls actually exposed
by render. Do not invent `--quality`, `--codec` or frame-rate flags because another
media tool uses those names.

Preserve a rate such as `24000/1001` or `30000/1001` exactly where the API supports
it. Record whether any conversion was intentional. Source frame rate can differ
from project or export frame rate. Matching a rounded decimal is insufficient for
an exact-frame request. Do not upscale a low-resolution input and claim newly
recovered detail.

For required stills, effects, HDR/color or independent audio, first check that the
installed native pipeline supports the needed behavior. If it does not, identify
the unmet requirement. An accepted fallback should be clearly labeled, with its
quality and editability tradeoffs, rather than silently substituted.

## Preserve the agreed grading domain

Inspect persisted `visualEffects.gradingMode` and `gradingDomain` when matching an
approved reference. Defaults are `native` Core Image source-layer grading and
`srgb`. Explicit `ffmpeg709` grades the composited image through RGB8 and
limited-range BT.709 YUV444 EQ before captions/overlays. Its domain is `srgb` for
sRGB input/output codes, `bt709` for BT.709 video codes retaining that interpretation,
or `bt709ToSRGB` for BT.709 codes deliberately interpreted as sRGB after EQ. The
two video domains require `ffmpeg709`.

Probe actual source and reference primaries, transfer, matrix and range with
`ffprobe`, and record the reference's intended output interpretation. Codec names,
extensions and a BT.709 matrix do not select the transfer function. A Rec.709
delivery tag does not select the grade's domain. Carry mode, domain and all intended
background, framing and animation settings forward in full effects replacements.

Measure representative decoded final frames against the approved reference under
matched geometry and color handling. Neutral `ffmpeg709` still performs a quantized
RGB/YUV round trip. Separate that baseline from grade differences, ICC conversion,
chroma subsampling and codec error. A precise color-chart match is not evidence of
whole-export or byte-for-byte canonical parity. Confirm actual foreground,
background and ungraded caption samples before reporting visual acceptance.
Keep approved source ranges unchanged when diagnosing motion-frame differences;
a different sampling policy is not corrected by silently shifting a requested trim.

## Measure audio before choosing a correction

Identify the approved audio source by content identity, source range and channel
layout. Record provenance locally before routing or replacement. A matching name
or a previous export is not proof that the source is approved. Preserve the source
and canonical export; use separate destinations for measurements and new masters.

For a loudness target, measure the intended full mix or approved source first.
Record integrated loudness, true peak, range, channel layout and measurement scope
with units. Use the supported measured or two-pass normalization workflow, carrying
the first pass's measurements into the correction pass as its contract requires.
Do not guess a gain from the requested target or treat source waveform amplitude
as delivered-mix loudness. Remeasure the final encoded artifact against both the
loudness target and peak ceiling; a gain adjustment can meet one and miss the other.
If the measurement or mastering control is absent, report that exact unmet need
instead of silently substituting an arbitrary gain or unrelated audio source.

### Native measurement and fixed mastering recipe

Discover `audio health --help`, `audio measure --help` and `audio master --help`
before using these commands. Health reports the detected FFmpeg executable,
engine version and `loudnorm` availability; it does not install a missing engine.

```sh
ed studio edit audio health --json
ed studio edit audio measure synthetic.openscreen --asset TRACK_ID --json
ed studio edit audio master synthetic.openscreen --track TRACK_ID --duration 10.01 --output ./synthetic-master-bundle --json
```

Replace `TRACK_ID` with the inspected independent track ID. Measurement follows
the processed audio reference when present and returns source SHA-256, integrated
LUFS, LRA in LU and true peak in dBTP. Silence has `silent: true` and absent
integrated/peak values; gated-out quiet audio may lack integrated LUFS without
being silent. Neither proves an integrated target was achieved.
`audio measure --asset TRACK_ID` measures referenced media, not the timeline mix
after track gain, fades or other audible tracks. For mix measurements, discover
`render-audio --help`, render a temporary PCM WAV, and measure that actual output
with the FFmpeg executable reported by Studio's `audio health`. Retain the measured
file's hash, command, engine and integrated/true-peak results.

Mastering reads the original source from sample zero, never looping or joining
it. Duration must fit the video, be at least 0.4 seconds and align to 48 kHz samples.
It resamples to stereo 48 kHz, trims exactly, applies a final 0.25-second linear
fade and runs measured two-pass loudnorm at fixed -16 LUFS, -1.5 dBTP and LRA 11.
There is no arbitrary mastering target option. A requested -18 LUFS target needs
a measured mix correction and final verification, not merely this recipe's success.

The 24-bit PCM WAV is independently remeasured before publication. Recipe checks
allow 0.3 LU integrated error, at most -1.4 dBTP and LRA 11.5 LU; these tolerances
do not override a stricter delivery ceiling. The new bundle contains read-only
`soundtrack.wav` and `report.json`, plus editable `project.openscreen` with a fresh
identity. Result `projectPath`, `audioPath` and `report` identify the actual output.
Retain prepared-source and post-master measurements, recipe, engine and hashes.

The selected track uses a derived asset at output/source zero, unity gain and no
timeline loops/fades; its fade is baked in. Original assets remain registered and
other tracks retain their settings. Remeasure the delivered mix after encoding:
the verified soundtrack alone does not certify other audible tracks or later gain.
Use normal AAC encoding for this PCM master; it cannot preserve AAC packets.

Existing bundle destinations are refused. Failed verification publishes no bundle
and leaves the input intact. A missing/damaged previous master can be recovered
from its intact original into a new bundle. Unshared obsolete derived references
are replaced; shared invalid media still blocks publication. Validate returned
provenance and composition instead of manually editing paths or overwriting a WAV.

### Meet a different target with measured timeline gain

For a single audible mastered track at unity gain, derive the correction from its
actual post-master measurement: `gainDb = targetLUFS - measuredLUFS`. For example,
-18 minus measured -16.02 LUFS gives -1.98 dB, not an assumed -2 dB. First inspect
the returned project's saved track ID, current gain, mute/loop and all audible
sources. With multiple tracks or existing processing, render and measure the actual
mix; do not extrapolate its loudness from one referenced asset's measurement.

Use `schema --operation audioOptions`. It requires gain, mute and loop values;
carry forward the inspected mute/loop choices. It updates these controls without
replacing timing or fades. This example assumes the inspected mastered track is
the only audible source, unmuted and unlooped; replace `TRACK_ID` with its saved ID
and -1.98 with the calculated correction:

```json
{
  "version": 1,
  "operations": [
    {"audioOptions": {"trackID": "TRACK_ID", "gainDb": -1.98, "muted": false, "loop": false}}
  ]
}
```

Save that public plan as `measured-gain.json`. Preserve the master WAV, report,
recipe and input project by applying to a new project variant:

```sh
revision=$(ed studio edit show synthetic-master-bundle/project.openscreen --summary --json | jq -er .revision)
ed studio edit apply synthetic-master-bundle/project.openscreen --plan measured-gain.json --output synthetic-target.openscreen --expect-revision "$revision" --dry-run --json
ed studio edit apply synthetic-master-bundle/project.openscreen --plan measured-gain.json --output synthetic-target.openscreen --expect-revision "$revision" --json
ed studio edit show synthetic-target.openscreen --json
ed studio edit validate synthetic-target.openscreen --json
ed studio edit render-audio synthetic-target.openscreen --output synthetic-target-mix.wav --container wav --sample-rate 48000 --channels 2 --json
```

Proceed only after the guarded dry-run passes. The master remains source/output
zero with its fade baked in; add no duplicate fade. Gain is an absolute saved
setting, finite from -60 through 12 dB. For a uniform mix correction with existing
gains, add the measured delta to each participating track's inspected gain only
when all audible sources can be adjusted coherently, then remeasure the mix.

Use the detected Studio FFmpeg executable, represented here by `$FFMPEG`, to
measure the rendered mix and the final encoded delivery separately:

```sh
"$FFMPEG" -hide_banner -i synthetic-target-mix.wav -af loudnorm=I=-18:TP=-1.5:LRA=11:print_format=json -f null -
ed studio edit render synthetic-target.openscreen --output synthetic-target.mp4 --audio-codec aac --json
"$FFMPEG" -hide_banner -i synthetic-target.mp4 -map 0:a:0 -af loudnorm=I=-18:TP=-1.5:LRA=11:print_format=json -f null -
```

These null-output commands retain loudnorm's `input_i` and `input_tp` as actual
input measurements, not its proposed normalized-output values. Recheck final
integrated loudness and true peak against the requested tolerances. Negative gain
reduces peaks; positive gain can exceed the ceiling. Iterate from actual mix and
delivery measurements when appropriate. If gain alone cannot meet both loudness
and peak requirements, report the remaining failure rather than claiming an
unsupported custom peak-limiting recipe. Gain-adjusted delivery requires encoding
and is ineligible for AAC packet copy, even if its source originally contained AAC.

## Treat passthrough as a compatibility claim

Use passthrough only when the public delivery contract and source packet metadata
establish compatibility. A shared codec name is insufficient: verify container
support, codec configuration, sample rate, channels/layout, packet timing and
boundaries, plus the absence of requested processing that would require decoding
and re-encoding. Inspect the actual delivery mode and any fallback reason. Do not
label a re-encode lossless or passthrough because it uses the same codec. When
passthrough was required, a fallback encode is a failed requirement unless approved.

### Approved AAC source branch

An approved canonical soundtrack can be sourced from an audio file or a video
container containing exactly one AAC stream. Use `addAudio` to import only its
audio. Keep original visual clips editable and preserve original music assets
when required. This is separate from mastering the original music to PCM.

After discovering render support, a compatible 48 kHz stereo example is:

```sh
ed studio edit render synthetic-copy.openscreen --output synthetic-copy.mp4 --audio-codec copy --audio-copy-track TRACK_ID --audio-sample-rate 48000 --audio-channels 2 --json
```

Copy selects the track's processed reference before its original. A mastered WAV
therefore fails AAC eligibility even if its original was AAC. Use the approved AAC
track, not the PCM master, when unchanged packets are the requirement.

Preflight requires exactly one audible independent track, no audible clip audio,
source/output zero, unity rate/gain, no loops, fades, envelopes or joins, and the
complete source duration matching both track and video. Sample rate/channels must
match without resampling. Partial `--start-frame`/`--end-frame` delivery is rejected.
MP4 supports H.264/HEVC, MOV supports ProRes; detected FFmpeg and ffprobe are required.

Full-stream priming, final partial packets, skip records and padding are supported;
duration need not divide evenly into 1024-sample packets. Ambiguous timing, gaps,
overlaps, missing codec configuration or unaccounted preroll reject. Native video
is rendered and remuxed with copied audio, then packet SHA-256, PTS/DTS, durations,
skip/padding, configuration, timebase and presentation bounds are verified before
publication. Retain `audioPassthrough` source hash, packet count, timebase and
`packetDataAndTimingVerified: true`, and independently inspect the final artifact.
Unsupported requests return `invalid_audio_copy`; backend/verification failures
have distinct errors. There is no silent encoding fallback. Do not claim the
installed app supports this until its own help and actual result confirm it.

## Render predictably

Choose a new destination for a new delivery. Use an explicit overwrite only when
replacing that output is intended. A render destination must not alias original
media, the project or an auxiliary input. Preserve a known-good output when a
replacement fails, and distinguish an old file from a newly published result by
checking the returned path, checksum and file metadata where available.

For faster iteration, sample targeted native frames or create a clearly labeled
review copy if the installed controls permit it. Render the final master from
the originals after the edit is accepted, using the agreed settings. Do not
promote a proxy to master by renaming it.

## Prove the file matches

Use the installed inspection API or a discovered media probe to read the actual
export's streams and properties. Container suffixes do not prove codec or stream
quality. Compare dimensions and rational rate exactly when required. Compare
duration with an explicit frame-based tolerance and account for the operation's
documented rounding or audio packet padding instead of accepting arbitrary drift.

Decode representative frames from the final file. Check orientation, scaling,
captions and cut boundaries. For exact-frame acceptance, inspect the affected
neighboring frames and confirm their timestamps. Check sound availability and
sync separately. If an export is missing a required track or differs from the
delivery contract, report it as a failed check and investigate the native settings
or render options before declaring success.
