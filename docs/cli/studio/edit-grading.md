# Native and FFmpeg-compatible grading

[Back to the CLI reference](../README.md)

`visualEffects.effects.gradingMode` selects the color-control semantics for a
clip. Omission uses `native`, which applies Core Image color controls to each
source layer in extended linear sRGB.

Use `ffmpeg709` when importing brightness, contrast and saturation from an
FFmpeg `eq` workflow using sRGB-encoded RGB8 and limited-range BT.709 YUV444:

```json
{
  "version": 1,
  "operations": [
    {
      "visualEffects": {
        "clipID": "photo",
        "effects": {
          "gradingMode": "ffmpeg709",
          "brightness": 0.002,
          "contrast": 1.02,
          "saturation": 1.035,
          "framing": "fullWidth",
          "background": { "blurRadius": 65 }
        }
      }
    }
  ]
}
```

The controls are parameters, not a preset: brightness supports -1 through 1,
contrast 0 through 4, and saturation 0 through 3 in this mode. Native mode
continues to allow saturation through 4. Gamma remains 1 in the FFmpeg reference.
Unknown modes and out-of-range values reject the edit transaction. Like other
visual settings, omitted fields reset to defaults when the operation replaces
the settings object.

## Processing order and color domain

1. Decode the original using its orientation and embedded ICC profile.
2. Apply optional exposure in linear light to the sources.
3. Place the foreground and independently crop, place and blur the background.
4. Composite the photo layers and project backdrop, including image framing.
5. Convert the composite from working linear sRGB to encoded sRGB, clip to the
   sRGB gamut and quantize to RGB8.
6. Convert to limited-range 8-bit BT.709 YUV444, apply the quantized FFmpeg EQ
   brightness/contrast/saturation transform, and convert back to RGB8.
7. Return to linear working color, then composite cursors, webcam and annotations.

Captions, caption gradients and other annotations remain ungraded. EQ runs after
background blur and compositing, so nonlinear clipping and quantization do not
change the relationship between foreground and background. The default native
mode retains its existing source-layer grading order.

Preview, native frame extraction, contact sheets and delivery all use the same
Core Image kernel. No per-frame subprocess, baked replacement source, external
runtime dependency or source-file mutation is involved. The inspector exposes
the same mode selector.

`ffmpeg709` specifies the YUV matrix and range, not a Rec.709 transfer curve.
Its RGB transfer is sRGB. Original P3 colors are color-managed into this working
domain before clipping. ICC normalization uses Core Image, and does not promise
byte-identical conversion to another ICC engine such as Pillow/ImageCms.

## Independent reference

The reference is FFmpeg 9.0.2, gamma 1, with no chroma subsampling or video codec:

```text
scale=in_range=full:out_range=limited:out_color_matrix=bt709,
format=yuv444p,
eq=brightness=B:contrast=C:saturation=S,
scale=in_range=limited:out_range=full:in_color_matrix=bt709,
format=rgba
```

Input and output are raw RGB8/RGBA8 pixels. FFmpeg receives the already
color-managed sRGB input raster; comparing different ICC normalization engines
would also measure their conversion differences. Codec delivery adds its own
chroma-subsampling and quantization budget.

Even neutral EQ uses the RGB8/YUV444 round trip in this mode. It is intentionally
not equivalent to bypassing color processing. EQ's integer parameter conversion
also makes small brightness changes discontinuous. These details matter when
matching an established reference.

## Measured precision

The independent reference was FFmpeg 9.0.2 on arm64 macOS. The kernel uses its
fixed-point RGB/YUV matrix coefficients, intermediate rounding, float-converted
EQ parameters, and output clipping behavior. This includes the reference's
signed fixed-point overflow behavior at extreme chroma. These are deliberate
version-specific semantics, rather than a promise to match every FFmpeg version,
pixel format, scaler flag or hardware backend.

The always-on test contains 24 RGB8 reference vectors captured independently
from FFmpeg. When FFmpeg is available, an additional 65,536-color test invokes
it directly. Neutral, target, stress, reduced controls, extremes and near-neutral
controls all measured zero differing channel bytes. Tests allow at most one
RGB8 level and mean absolute error 0.01 for platform arithmetic variation.

Actual CLI frame extraction, with both output PNGs color-managed to sRGB before
sampling the 24 patch centers, measured:

| Controls: contrast / saturation / brightness | RGB8 maximum | Mean absolute error |
| --- | ---: | ---: |
| Neutral: 1 / 1 / 0 | 1 | 0.0972 |
| Target: 1.02 / 1.035 / 0.002 | 1 | 0.0556 |
| Stress: 1.1 / 1.2 / 0.03 | 1 | 0.0417 |

Composed synthetic sRGB and P3 originals were also tested at 2160 × 3840 and
540 × 960, with full-width foregrounds and radius-65 backgrounds. Here the
independent reference receives an extracted, ungraded sRGB8 frame, introducing
an extra raster quantization and color-conversion round trip relative to grading
inside the floating-point graph. Neutral maximum error was 4 to 5 levels;
target and stress maxima were 6 and 7. Across these cases mean absolute error
was 0.279 to 0.711. These end-to-end bounds are separate from the kernel's
RGB8-to-RGB8 comparison and were calibrated with the neutral round trip first.

The reference input is the same composited raster, not separately graded layers.
Sources retain their checksums. An additional HEVC10 delivery check covers a P3
original and ungraded caption colors. Neutral and stress deliveries both differed
from their native frames by at most one RGB8 level at the foreground, background
and caption samples. The codec test allows four levels for encoder variation;
this budget is separate from EQ precision.
