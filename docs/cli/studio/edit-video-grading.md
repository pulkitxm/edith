# Encoded video grading domains

[Back to the CLI reference](../README.md)

`gradingMode: "ffmpeg709"` supports an explicit per-clip `gradingDomain`.
Use it to distinguish photo RGB codes from BT.709 video codes before applying
brightness, contrast and saturation. Defaults remain `gradingMode: "native"`
and `gradingDomain: "srgb"`.

| Domain | EQ input RGB codes | Interpretation of graded RGB codes |
| --- | --- | --- |
| `srgb` | sRGB | sRGB |
| `bt709` | Core Video BT.709 | Core Video BT.709 |
| `bt709ToSRGB` | Core Video BT.709 | sRGB |

The two video domains require `gradingMode: "ffmpeg709"`. There is no automatic
guess based on the filename, container or clip type. Inspect the source transfer
and the reference pipeline's output interpretation. A video tagged with an sRGB
transfer still uses the `srgb` domain. A BT.709 matrix alone does not establish
the transfer function.

For mixed reference pipelines that EQ BT.709 video code values but place those
values into an sRGB final raster, use:

```json
{
  "visualEffects": {
    "clipID": "video",
    "effects": {
      "gradingMode": "ffmpeg709",
      "gradingDomain": "bt709ToSRGB",
      "contrast": 1.02,
      "saturation": 1.035,
      "brightness": 0.002,
      "framing": "fill"
    }
  }
}
```

Use `bt709` instead when the graded reference remains BT.709 video and is viewed
with that transfer interpretation. Photo clips can keep `srgb` or omit the
domain. Omitted settings reset to defaults when `visualEffects` replaces the
settings object, so include background, crop-independent framing and animation
settings that the clip should retain.

## Why the domains differ

AVFoundation decodes a tagged video into a color-managed Core Image graph.
Encoding those linear working values as sRGB before EQ does not recover the
source video's BT.709 encoded values. A difference of several RGB8 levels can
therefore remain even when frame content, matrix, range and numeric EQ controls
agree. A post-render tone curve is insufficient: EQ clipping and quantization
already happened in the wrong domain, and such a curve would also affect text.

The video domains instead color-match the composed image from working linear
sRGB into the BT.709 video profile created by
`CVImageBufferCreateColorSpaceFromAttachments`, with BT.709 primaries, transfer
and matrix attachments. This follows the same platform interpretation as the
AVFoundation decoder. It deliberately does not substitute the distinct
`CGColorSpace.itur_709` display profile or a hand-written approximate gamma.

The existing fixed-point limited-range YUV444 EQ runs on those RGB8 codes.
After EQ, the chosen domain converts the resulting codes back into working
linear color using either the video profile or the sRGB transfer. Captions and
other overlays are composed afterward. Preview, frame extraction, contact
sheets and encoded delivery use this same graph.

Full-range and legal-range source decoding happens once in AVFoundation. The
grading stage operates on decoded RGB and uses EQ's limited-range YUV
intermediate, so it does not apply a second source-range expansion. Exposure,
crop, framing and background composition still happen before EQ.

## Output color and reference normalization

`gradingDomain` defines a clip's grade, not the delivery container's tags.
The project and delivery color-space settings still control output encoding.
For example, `bt709ToSRGB` can be delivered as a correctly tagged Rec.709 or P3
video while preserving its intended sRGB-normalized appearance. P3 output does
not turn EQ into a wide-gamut algorithm: the grade's intermediate remains
RGB8 with BT.709/sRGB primaries. P3 sources are color-managed into that domain.

Comparisons must normalize both artifacts using their actual color metadata.
For an independent raw FFmpeg RGB reference, assigning sRGB to the returned
codes represents `bt709ToSRGB`; assigning the Core Video BT.709 profile represents
`bt709`. Changing the interpretation is not a color conversion and must be an
explicit part of the reference contract. An untagged PNG, a tagged BT.709 video
and a color-managed screenshot are not interchangeable references.

## Synthetic reference fixtures

The regression fixtures are genuinely encoded videos created from synthetic
color patches. Full- and limited-range fixtures explicitly set BT.709 frame
metadata with `setparams` before encoding, and assert the decoded stream's
primaries, transfer, matrix and range. Encoder command-line color flags alone
can be overridden by propagated image-frame metadata in FFmpeg 9.0.2.

The independent reference decodes the fixture, scales with Lanczos in the
declared source range to limited-range BT.709, applies FFmpeg EQ, and converts
to raw RGBA8. Tests compare color-managed patch centers after assigning the
declared reference interpretation. This avoids PNG metadata ambiguity and
separates flat-color grading precision from scaler-edge and chroma-subsampling
differences. Neutral, target and stress controls are tested at FHD and 4K.

## Measured correction

FFmpeg 9.0.2 generated the independent reference. Actual CLI frame extraction
and HEVC10 delivery were compared at 24 patch centers, after both the native
artifact and independently encoded reference were decoded by AVFoundation and
normalized to sRGB. The target controls were contrast 1.02, saturation 1.035 and
brightness 0.002. The reference output in this table interprets video EQ codes
as sRGB, matching `bt709ToSRGB`:

| Source codec / range | Existing `srgb` domain MAE | `bt709ToSRGB` frame MAE | Delivered MAE | Delivered p95 / max |
| --- | ---: | ---: | ---: | ---: |
| H.264 / full | 8.7917 | 0.6528 | 0.6944 | 2 / 2 |
| H.264 / limited | 9.0417 | 0.2500 | 0.3194 | 1 / 2 |
| HEVC10 / full | 8.3194 | 0.6389 | 0.7361 | 2 / 3 |
| HEVC10 / limited | 9.2778 | 0.6528 | 0.6944 | 2 / 6 |

Errors are RGB8 levels. These are measurements of synthetic tagged fixtures,
not guarantees for arbitrary media, scaling edges or encoders. The remaining
error includes native versus FFmpeg decoder rounding, chroma reconstruction,
10-bit-to-8-bit conversion and the RGB/YUV EQ round trip. Neutral fixtures
calibrate that floor independently; their FHD/4K patch maximum was four levels.
Across neutral, target and stress fixtures, the native frame tests enforce
maximum six and MAE 1.5. P3 and Rec.709 delivery tests additionally cover
ungraded caption colors and source preservation.

A separate FHD encoded motion fixture compares every RGB channel in the frame,
including chroma boundaries, against the independently decoded FFmpeg raster.
It measured MAE 0.9379 and p95 2, within the test's MAE 2 and p95 4 bounds.

The original `srgb` photo-domain kernel and composition tests remain in the
suite. The new domains do not change its transfer functions or defaults.
