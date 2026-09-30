# Photo backgrounds and effects

## Preserve editable originals

Use `addStill` for a photo with an explicit duration, then `visualEffects` for
per-clip presentation. Inspect `schema --operation visualEffects` before building
the plan. Each operation accepts a persisted clip ID or a plan-local alias from an
earlier import. Apply the intended settings to every selected clip; changing one
clip does not set a project-wide photo style.

For a project already configured with the requested canvas and cadence, this
imports an original for 1.001 seconds and places it over its own blurred background:

```json
{
  "version": 1,
  "operations": [
    {"addStill": {"path": "synthetic-landscape.png", "name": "photo", "duration": 1.001}},
    {"visualEffects": {"clipID": "photo", "effects": {"framing": "fullWidth", "background": {}}}}
  ]
}
```

The background reads the original with orientation and embedded color profile
applied; it does not create a baked replacement image. Keep that original available
and unchanged. Both layers remain part of the native project.

## Choose foreground and background separately

Foreground `framing` is `fit`, `fill` or `fullWidth`. `fit` contains the selected
source rectangle; `fill` covers the canvas and clips overflow at the focal point.
`fullWidth` preserves aspect ratio and scales to canvas width, centered at the
default focal point `(0.5, 0.5)`. A tall image may extend above and below the canvas;
use `fit` when its entire height must remain visible. Project padding, keyframes
and zoom can alter the final foreground placement, so verify rendered coverage.

The existing `crop` and `resetCrop` operations affect only the foreground source
rectangle. The background starts from the uncropped original, independently of
the foreground crop or motion. Its settings are:

| Field | Default | Meaning |
| --- | --- | --- |
| `framing` | `fill` | Independent `fit`, `fill` or `fullWidth` |
| `focalX`, `focalY` | `0.5` | Normalized fractions from left/top, 0 through 1 |
| `blurRadius` | `65` | Gaussian radius in project-canvas pixels, 0 through 1000 |
| `sourceCrop` | Entire original | Normalized oriented-original `x`, `y`, `width`, `height` |

For `sourceCrop`, width and height are 0.05 through 1, x and y are 0 through 0.95,
and each origin plus dimension must stay within 1. Crop precedes background framing.
For example, `{"x":0.1,"y":0.1,"width":0.8,"height":0.8}` selects an independent
central background region while preserving foreground crop settings.

Radius is stored at native canvas resolution. A 540 by 960 preview of a 2160 by
3840 project scales radius 65 to 16.25. Do not multiply the stored radius to
compensate for a smaller preview. Background edges are clamped before blur;
`fit` and `fullWidth` backgrounds can still reveal the project backdrop outside
their placed rectangle. Inspect the native-resolution output as well as previews.

## Replace settings deliberately

`visualEffects` replaces the complete settings object; it is not a partial patch.
Its effect fields are optional, but omitted values reset to defaults: fit framing,
centered focal point, zero exposure/brightness, contrast/saturation 1, no keyframes
and no clip background. An empty `background` object enables the defaults above.
Omitting `background` disables it. Null and unknown fields are rejected.

Before updating one effect, inspect full `show` and carry forward every setting
that should remain in the replacement object. In particular, sending only a new
background can reset foreground framing and grade. A keyframe requires `time`;
omitted transform fields are identity values and interpolation defaults to linear.

## Verify layers and appearance

Both foreground and background receive the clip's exposure and color controls
before captions. Default native grading uses Core Image semantics; matching
FFmpeg `eq` numbers does not establish matching pixels. Compare decoded frames
to the approved reference with explicit geometry, color handling and tolerances.
Do not claim cross-renderer parity from saved settings alone.

Verify each selected clip's persisted settings, then sample wide and tall photos,
foreground crop boundaries and background edges in the rendered result. On a
disposable variant, change an effect through another public plan and verify the
new pixels while the accepted project and originals remain unchanged. This checks
both native editability and rendered behavior without baking replacement media.
