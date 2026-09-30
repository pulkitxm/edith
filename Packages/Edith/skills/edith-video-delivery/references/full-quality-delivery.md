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

Use original media, not a previous review encode, as the source for the master.
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

## Treat passthrough as a compatibility claim

Use passthrough only when the public delivery contract and source packet metadata
establish compatibility. A shared codec name is insufficient: verify container
support, codec configuration, sample rate, channels/layout, packet timing and
boundaries, plus the absence of requested processing that would require decoding
and re-encoding. Inspect the actual delivery mode and any fallback reason. Do not
label a re-encode lossless or passthrough because it uses the same codec. When
passthrough was required, a fallback encode is a failed requirement unless approved.

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
