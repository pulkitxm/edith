# Editable caption styles

[Back to the CLI reference](../README.md)

Caption typography and lower-frame gradients stay editable in the native editor,
CLI, edit plans and MCP. Styling never converts a caption to an image or changes
its existing timing anchor. The native Captions panel has a Style & position
inspector with font, layout and advanced effect editing.

## Add or restyle a caption

```sh
ed studio edit captions add demo.openscreen \
  --text 'SYNTHETIC CAPTION' --start-frame 120 --end-frame 240 --fps 60 \
  --style caption-style.json

ed studio edit captions update demo.openscreen annotation_example \
  --style caption-style.json --dry-run

ed studio edit captions update demo.openscreen annotation_example \
  --style caption-style.json

ed studio edit captions list demo.openscreen
```

`--style` reads a strict JSON file, up to 64 KiB. It replaces the complete saved
style. Omit an optional `outline`, `shadow` or `gradient` to remove that effect.
Omitting `--style` preserves the saved style. Add, update and list return that
style alongside the stable caption ID and exact output anchor. Dry runs return
the proposed style without modifying project bytes.

Installed font family and face are required. `Arial` with `Bold Italic` or
`BoldItalic` selects Arial Bold Italic. Missing families or faces fail with
`font_not_found`; they are never silently substituted.

## Reference-canvas pixel coordinates

All dimensions are pixels in the explicit `canvasWidth` by `canvasHeight`
reference canvas. The shared native-preview, frame and export renderer scales
them to its output canvas. There are no implicit 1280-pixel font-size units.

- `fontSize` is the font's pixel size, not the measured height of capital letters.
- `lineAdvance` is the exact distance between successive baselines, including
  explicit newlines and automatically wrapped lines.
- `width` is the wrapping box width. `alignment` is `left`, `center` or `right`
  and also determines which horizontal edge or center of that box `x` anchors.
- `y` increases downwards from the top of the canvas. `anchor` is `top`, `center`
  or `bottom` of the typographic block, including the font's ascent and descent.
- sRGB channels and alpha are fractions in `[0, 1]`. Thus black alpha 70/255 is
  `0.27450980392156865`, and black alpha 100/255 is `0.39215686274509803`.
- `outline.width` is the outward stroke width in pixels.
- Shadow `x` and `y` are offsets, with positive Y downwards. `blur` and
  `strokeWidth` are pixels. A zero stroke width uses the filled glyph shape.
- `gradient.startY` and `endY` are top-origin pixel coordinates. Stop `location`
  values are strictly increasing fractions over that extent, starting at 0 and
  ending at 1. The first and last colors extend flat outside the extent.

Invalid numbers, alpha ranges, nested fields, fonts and text layouts that exceed
the reference canvas fail validation. A gradient belongs to its caption and is
visible only during that caption's interval. Avoid overlapping identical
gradients if you do not want their opacity to accumulate.

This complete synthetic example uses a 2160 by 3840 canvas, centered multiline
text at top-origin Y 2780, 104-pixel Arial Bold Italic and 150-pixel line advance.
Changing `fontSize` to 112 retains the exact line advance and position.

```json
{
  "canvasWidth": 2160,
  "canvasHeight": 3840,
  "fontFamily": "Arial",
  "fontStyle": "Bold Italic",
  "fontSize": 104,
  "lineAdvance": 150,
  "alignment": "center",
  "anchor": "top",
  "x": 1080,
  "y": 2780,
  "width": 2000,
  "fill": { "red": 1, "green": 1, "blue": 1, "alpha": 1 },
  "outline": {
    "width": 1,
    "color": { "red": 0, "green": 0, "blue": 0, "alpha": 0.27450980392156865 }
  },
  "shadow": {
    "x": 3,
    "y": 7,
    "blur": 9,
    "strokeWidth": 7,
    "color": { "red": 0, "green": 0, "blue": 0, "alpha": 1 }
  },
  "gradient": {
    "startY": 2100,
    "endY": 3600,
    "stops": [
      { "location": 0, "color": { "red": 0, "green": 0, "blue": 0, "alpha": 0 } },
      { "location": 1, "color": { "red": 0, "green": 0, "blue": 0, "alpha": 0.39215686274509803 } }
    ]
  }
}
```

## Batch plans and MCP

`ed studio edit schema` and the MCP `edith_studio_edit_schema` tool expose the
same strict nested JSON Schema, including caption styles, gradient stops and
exact-frame anchors.

The `text` operation accepts an optional `style` and retains its source-ruler
timing semantics. The `outputCaption` operation uses exact output frames. Omit
`id` to create a caption; provide an existing caption ID to replace its text and
anchor. An omitted style on replacement preserves its saved style.

```json
{
  "version": 1,
  "operations": [
    {
      "outputCaption": {
        "content": "SYNTHETIC\nCAPTION",
        "anchor": {
          "start": { "frame": 120, "frameRate": { "numerator": 60, "denominator": 1 } },
          "end": { "frame": 240, "frameRate": { "numerator": 60, "denominator": 1 } }
        }
      }
    }
  ]
}
```

Add the full `style` object from above inside `outputCaption` to style it in the
same transaction. For existing captions, a `captionStyle` operation takes `id`
and the full `style` object and leaves text and exact timing untouched. A single
plan can contain 47 such operations, or up to the normal 1000-operation plan
limit, with one atomic save. Any invalid operation rolls back the entire plan.

```sh
ed studio edit apply demo.openscreen --plan captions.json --dry-run
ed studio edit apply demo.openscreen --plan captions.json --overwrite
```

MCP uses the same CLI arguments through `edith_studio_edit_captions_add`,
`edith_studio_edit_captions_update`, `edith_studio_edit_captions_list` and
`edith_studio_edit_apply`. Frame and marker snapshot timing remains unchanged
through later speed changes, clip reordering and marker edits.
