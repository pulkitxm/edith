# Original-derived clip backgrounds

[Back to the CLI reference](../README.md)

`ed studio edit apply` accepts an optional `background` object inside each clip's
`visualEffects.effects`. The background always uses that clip's original media,
with image orientation and embedded color profile applied. No replacement asset
or baked image is created. Preview, frame extraction, contact sheets and export
use the same native render pipeline.

Border review continues to assess foreground source coverage. It identifies the
intentional original-derived layer with `original_background_fit`,
`original_background_fill`, or `original_background_fullWidth`, plus
`original_background_blur` when the radius is positive. Foreground-uncovered
canvas samples can therefore be intentional background regions.

For a 2160 × 3840 canvas, this places a landscape photo at full canvas width,
centered vertically, over an independently filled original with radius 65:

```json
{
  "version": 1,
  "operations": [
    {
      "visualEffects": {
        "clipID": "photo",
        "effects": {
          "framing": "fullWidth",
          "background": { "blurRadius": 65 }
        }
      }
    }
  ]
}
```

`photo` can be an actual clip ID or an alias from an earlier `addStill` operation
in the same plan. Apply the operation to each of the 18 clip IDs for an 18-photo
sequence; settings are per clip. Inspect `ed studio edit schema` for machine-readable
fields and `ed studio edit show` for persisted settings. Use `ed studio edit apply --dry-run`
to validate the complete plan without changing the project.

## Foreground geometry

- `fit` retains the entire selected source rectangle, with letterboxing if needed.
- `fill` covers the canvas, clipping overflow according to the focal point.
- `fullWidth` scales the selected source rectangle to canvas width, preserving
  aspect ratio. With zero project padding and neutral keyframes/zoom, it is
  exactly full width and centered by the default focal point `(0.5, 0.5)`.
  A rectangle taller than the canvas extends beyond its top and bottom. Use
  `fit` when the entire tall image must remain visible.
- The existing `crop` operation selects the foreground rectangle in normalized,
  oriented source coordinates. `resetCrop` restores the whole foreground source.
  Neither operation affects the background.
- Project padding reduces foreground scale. Source-time keyframes and zoom
  regions apply after base framing, so a scale above 1 can clip a previously
  contained foreground. Background placement is unaffected by this motion.

## Background settings

| Field | Default | Meaning |
| --- | --- | --- |
| `framing` | `fill` | `fit`, `fill`, or `fullWidth`, independent of foreground |
| `focalX`, `focalY` | `0.5` | Fractions from left/top, each from 0 through 1 |
| `blurRadius` | `65` | Core Image Gaussian radius in project-canvas pixels, 0 through 1000 |
| `sourceCrop` | entire original | `{ "x", "y", "width", "height" }`, normalized oriented-original coordinates |

Crop dimensions are each 0.05 through 1. Origins are each 0 through 0.95;
`x + width` and `y + height` must not exceed 1. All values must be finite.
Background crop is applied directly to the original, before its independent
framing. Both layers receive the clip's exposure and color controls. Background
edges are clamped before Gaussian blur, avoiding transparent or dark edge halos.
Fit and full-width backgrounds may intentionally leave the project backdrop
visible outside their placed rectangle.

Radius is expressed at the project's native canvas size. A 540 × 960 preview
of a 2160 × 3840 canvas uses radius 16.25 for a stored radius of 65. Export and
full-resolution frame extraction decode the original at full resolution.

## Defaults and replacement

`visualEffects` replaces the complete visual settings object. Omitted fields
reset to fit framing, centered focal point, exposure/brightness 0,
contrast/saturation 1, no keyframes, and no clip background. An empty background
object enables its defaults. Omit `background` to disable it. Null values and
unknown plan fields are rejected. A keyframe requires only `time`; omitted
transform fields use identity values and interpolation defaults to `linear`.

The inspector exposes the same background fields and full-width foreground
framing. Color controls use Core Image semantics, not FFmpeg `eq` semantics;
equal numeric values across these filters do not establish pixel parity.

## Measured grading reference

A synthetic 24-patch sRGB chart rendered through the native `frame` command was
compared with FFmpeg 9.0.2. Each patch was 64 × 64 pixels. Comparison sampled
each patch center after color-managed conversion of both PNGs to sRGB RGB8.
The FFmpeg reference used explicit BT.709 limited-range 8-bit YUV444 between
RGB input/output, with these filters:

```text
scale=in_range=full:out_range=limited:out_color_matrix=bt709,
format=yuv444p,
eq=brightness=0.03:contrast=1.1:saturation=1.2,
scale=in_range=limited:out_range=full:in_color_matrix=bt709,
format=rgb24
```

With neutral controls, the mean absolute channel difference was 0.375 levels
and maximum difference was 1 level. With brightness 0.03, contrast 1.1 and
saturation 1.2, the mean difference was 10.917 levels and maximum difference
was 51 levels. These are measurements of this reference, not a tolerance
guarantee for other images or FFmpeg conversion settings.

Edith's native pipeline uses extended linear sRGB as its working space and
`CIColorControls`. The reference `eq` adjusts encoded YUV luma/chroma, with
different contrast pivots, clipping and quantization. Matching the numeric
controls cannot match these processing domains. Native grading therefore has
no FFmpeg-parity mode.
