# Editable caption styles

Discover `schema --operation outputCaption`, `schema --operation captionStyle`
and `captions add --help` on the intended executable. Keep text, exact timing and
style editable rather than baking reference captions into replacement media.

## Output-time batches

`outputCaption` uses an inclusive start and exclusive end in exact output frames.
Omit `id` to create; supply a saved caption ID to replace its text and anchor.
Omitting style during replacement retains the saved style. The separate `text`
operation still uses the source ruler, not these output anchors.

```json
{
  "version": 1,
  "operations": [
    {
      "outputCaption": {
        "content": "SYNTHETIC\nCAPTION",
        "anchor": {
          "start": { "frame": 0, "frameRate": { "numerator": 30000, "denominator": 1001 } },
          "end": { "frame": 30, "frameRate": { "numerator": 30000, "denominator": 1001 } }
        },
        "style": {
          "canvasWidth": 540, "canvasHeight": 960,
          "fontFamily": "Arial", "fontStyle": "Bold Italic",
          "fontSize": 26, "lineAdvance": 38,
          "alignment": "center", "anchor": "top", "metrics": "fontBounds",
          "x": 270, "y": 700, "width": 500,
          "fill": { "red": 1, "green": 1, "blue": 1, "alpha": 1 }
        }
      }
    }
  ]
}
```

Batch captions in one guarded plan within the usual 1000-operation limit. For a
style-only batch, use `captionStyle` with `id` and a complete `style`; text and
timing stay unchanged. `captions add`/`update --style FILE` read strict JSON up to
64 KiB. A supplied style replaces the entire saved style, so omitting optional
`outline`, `shadow` or `gradient` removes that effect. List and inspect actual
caption IDs after applying; dry-run IDs are not saved identities.

## Map reference typography precisely

All sizes and positions are pixels in `canvasWidth` by `canvasHeight`, scaled to
the rendered canvas. `fontSize` is font size, not visible capital height.
`lineAdvance` is baseline-to-baseline distance, including wrapped lines. `width`
is the wrapping box; left/center/right `alignment` sets how `x` anchors that box.
`y` increases downward, and `anchor` places the typographic block by top, center
or bottom, including ascent/descent. Installed family and face are required;
missing fonts or unsupported glyphs reject rather than silently substitute.

Use `metrics: "fontBounds"` for a Pillow BASIC reference: integer ascent/descent
and font bounding-box width, without automatic kerning or ligatures. Centered
pen X is `x - (box.right - box.left) / 2`, including negative left bearings.
Omission or `typographic` retains native typographic positioning. Choose from
the reference's layout contract, not just the apparent font name. Compare glyph
bounds and masks with declared rasterizer tolerances rather than claiming identical
antialiasing. Do not move an approved text anchor to conceal a layout mismatch.

## Effects and compositing

Colors use fractional sRGB `red`, `green`, `blue`, `alpha` in `[0,1]`.
`outline` takes outward pixel `width` and `color`. `shadow` takes pixel `x`, `y`,
`blur`, `strokeWidth`, fill `color`, and optional independent `strokeColor`.
Omitted stroke color uses fill color. Fill/stroke alpha are assigned separately
before blur and offset; the interior does not accumulate both opacities.

`gradient` takes top-origin `startY`, `endY`, and `stops` with strictly increasing
`location` fractions from 0 to 1 and RGBA `color`. Endpoint colors extend outside
the extent. It belongs to the caption interval; overlapping gradients accumulate.

Styled gradient, shadow and outlined text composite in that order using encoded
sRGB source-over, independently of the metrics mode. Black alpha `100/255` over
white 255 yields 155, not linear-light 204. There is no separate blend-mode flag.
Verify outside-glyph gradient samples separately from glyph-edge antialiasing,
and check decoded delivery frames as well as native frames.

For an editor handoff, changed caption inspector drafts count as unsaved work.
An `editor_busy` result requires the user's explicit commit or discard, followed
by a fresh request and acknowledgement; do not overwrite drafts from the CLI.
