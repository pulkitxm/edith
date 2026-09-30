import copy
import ctypes as ct
import math
import shutil

from editor_acceptance_contracts import require
from editor_parity_fixtures import command
from editor_parity_pixels import calibrated_comparison, codec_control, offsets
from editor_parity_glyphs import ink_mask


class Rectangle(ct.Structure):
    _fields_ = [(name, ct.c_int) for name in ("x", "y", "width", "height")]


class PangoCanvas:
    def __init__(self, width, height):
        paths = [line.strip().split(" (", 1)[0] for line in command(["otool", "-L", shutil.which("pango-view")]).decode().splitlines()[1:]]
        self.libraries = [ct.CDLL(next(path for path in paths if name in path)) for name in
                          ("/libcairo.", "/libpango-1.0.", "/libpangocairo-1.0.", "/libgobject-2.0.")]
        p, d, i, s = ct.c_void_p, ct.c_double, ct.c_int, ct.c_char_p
        signatures = {
            "cairo_image_surface_create": (p, [i, i, i]), "cairo_create": (p, [p]),
            "cairo_destroy": (None, [p]), "cairo_surface_destroy": (None, [p]),
            "cairo_surface_flush": (None, [p]), "cairo_image_surface_get_data": (p, [p]),
            "cairo_image_surface_get_stride": (i, [p]), "cairo_move_to": (None, [p, d, d]),
            "cairo_set_source_rgba": (None, [p, d, d, d, d]), "cairo_fill": (None, [p]),
            "cairo_stroke_preserve": (None, [p]), "cairo_set_line_width": (None, [p, d]),
            "cairo_set_line_join": (None, [p, i]), "cairo_scale": (None, [p, d, d]),
            "cairo_font_options_create": (p, []), "cairo_font_options_destroy": (None, [p]),
            "cairo_font_options_set_hint_style": (None, [p, i]), "cairo_font_options_set_hint_metrics": (None, [p, i]),
            "cairo_font_options_set_antialias": (None, [p, i]),
            "pango_cairo_create_layout": (p, [p]), "pango_cairo_layout_path": (None, [p, p]),
            "pango_layout_get_context": (p, [p]), "pango_cairo_context_set_font_options": (None, [p, p]),
            "pango_context_set_round_glyph_positions": (None, [p, i]),
            "pango_font_description_from_string": (p, [s]), "pango_font_description_free": (None, [p]),
            "pango_font_description_set_absolute_size": (None, [p, d]),
            "pango_layout_set_font_description": (None, [p, p]), "pango_layout_set_markup": (None, [p, s, i]),
            "pango_layout_get_baseline": (i, [p]), "pango_layout_get_extents": (None, [p, ct.POINTER(Rectangle), ct.POINTER(Rectangle)]),
            "g_object_unref": (None, [p]),
        }
        for name, (result, arguments) in signatures.items():
            function = next(getattr(lib, name) for lib in self.libraries if hasattr(lib, name))
            function.restype, function.argtypes = result, arguments
            setattr(self, name, function)
        self.width, self.height = width, height
        self.surface = self.cairo_image_surface_create(0, width, height)
        self.context = self.cairo_create(self.surface)

    def close(self):
        self.cairo_destroy(self.context)
        self.cairo_surface_destroy(self.surface)

    def text(self, text, style):
        import html
        layout = self.pango_cairo_create_layout(self.context)
        options = self.cairo_font_options_create()
        font = self.pango_font_description_from_string(f"{style['fontFamily']} {style['fontStyle']}".encode())
        try:
            self.cairo_font_options_set_hint_style(options, 1)
            self.cairo_font_options_set_hint_metrics(options, 1)
            self.cairo_font_options_set_antialias(options, 2)
            context = self.pango_layout_get_context(layout)
            self.pango_cairo_context_set_font_options(context, options)
            self.pango_context_set_round_glyph_positions(context, 0)
            self.pango_font_description_set_absolute_size(font, style["fontSize"] * 1024)
            self.pango_layout_set_font_description(layout, font)
            markup = f'<span font_features="kern=0,liga=0">{html.escape(text)}</span>'.encode()
            self.pango_layout_set_markup(layout, markup, -1)
            ink, logical = Rectangle(), Rectangle()
            self.pango_layout_get_extents(layout, ct.byref(ink), ct.byref(logical))
            ascent = self.pango_layout_get_baseline(layout) / 1024
            return layout, ink, logical, ascent
        except BaseException:
            self.g_object_unref(layout)
            raise
        finally:
            self.pango_font_description_free(font)
            self.cairo_font_options_destroy(options)

    def glyph_layer(self, text, style):
        scale = self.width / style["canvasWidth"]
        self.cairo_scale(self.context, scale, self.height / style["canvasHeight"])
        self.cairo_set_line_join(self.context, 1)
        layouts = [self.text(line, style) for line in text.split("\n")]
        try:
            ascent = math.ceil(layouts[0][3])
            descent = math.ceil(layouts[0][2].height / 1024 - layouts[0][3])
            block_height = ascent + descent + (len(layouts) - 1) * style["lineAdvance"]
            top = style["y"] - {"top": 0, "center": block_height / 2, "bottom": block_height}[style["anchor"]]
            def paint(color):
                self.cairo_set_source_rgba(self.context, *(color[key] for key in ("red", "green", "blue", "alpha")))
            def draw(offset_x, offset_y, stroke, fill):
                for index, (layout, ink, logical, baseline) in enumerate(layouts):
                    extent = math.ceil(max(logical.width, ink.x + ink.width) / 1024) - math.floor(min(0, ink.x) / 1024)
                    x = style["x"] - {"left": 0, "center": extent / 2, "right": extent}[style["alignment"]]
                    self.cairo_move_to(self.context, x + offset_x, top + ascent - baseline + index * style["lineAdvance"] + offset_y)
                    self.pango_cairo_layout_path(self.context, layout)
                    if stroke:
                        paint(stroke["color"])
                        self.cairo_set_line_width(self.context, 2 * stroke["width"])
                        self.cairo_stroke_preserve(self.context)
                    paint(fill)
                    self.cairo_fill(self.context)
            if shadow := style.get("shadow"):
                require(shadow["blur"] == 0, "Independent styled reference requires the declared zero-blur shadow")
                draw(shadow["x"], shadow["y"], {"width": shadow["strokeWidth"], "color": shadow["strokeColor"]}, shadow["color"])
            draw(0, 0, style.get("outline"), style["fill"])
            self.cairo_surface_flush(self.surface)
            stride = self.cairo_image_surface_get_stride(self.surface)
            require(stride == self.width * 4, "Unexpected independent Cairo stride")
            return ct.string_at(self.cairo_image_surface_get_data(self.surface), stride * self.height)
        finally:
            for layout, _, _, _ in layouts:
                self.g_object_unref(layout)


def compose_encoded_style(background, layer, style, width, height):
    require(len(background) == width * height * 3 and len(layer) == width * height * 4, "Invalid styled composition rasters")
    data = bytearray(background)
    if gradient := style.get("gradient"):
        tables = {}
        for y in range(height):
            position = ((y + 0.5) * style["canvasHeight"] / height - gradient["startY"]) / (gradient["endY"] - gradient["startY"])
            stops = gradient["stops"]
            left, right = next(((a, b) for a, b in zip(stops, stops[1:]) if position <= b["location"]), (stops[-2], stops[-1]))
            weight = max(0, min(1, (position - left["location"]) / (right["location"] - left["location"])))
            color = {key: left["color"][key] * (1 - weight) + right["color"][key] * weight for key in left["color"]}
            if color["alpha"] == 0:
                continue
            for channel, name in enumerate(("red", "green", "blue")):
                key = (color[name], color["alpha"])
                if key not in tables:
                    tables[key] = bytes(round(value * (1 - color["alpha"]) + 255 * color[name] * color["alpha"]) for value in range(256))
                start, end = y * width * 3 + channel, (y + 1) * width * 3
                data[start:end:3] = data[start:end:3].translate(tables[key])
    for index, alpha in enumerate(layer[3::4]):
        if alpha:
            for channel in range(3):
                premultiplied = layer[index * 4 + 2 - channel]
                data[index * 3 + channel] = round(premultiplied + data[index * 3 + channel] * (255 - alpha) / 255)
    return bytes(data)


def styled_reference(background, text, style, width, height):
    canvas = PangoCanvas(width, height)
    try:
        layer = canvas.glyph_layer(text, style)
    finally:
        canvas.close()
    return compose_encoded_style(background, layer, style, width, height), layer


def check_encoded_blend_region(actual, width, height, background_rgb):
    require(len(actual) == width * height * 3, "Invalid encoded blend probe raster")
    expected = tuple((value * 155 + 127) // 255 for value in background_rgb)
    indices = offsets(width, height, (0.05, 0.9, 0.1, 0.05))
    require(indices, "Encoded blend probe region is empty")
    error = max(abs(actual[index + channel] - expected[channel]) for index in indices for channel in range(3))
    require(error <= 1, f"Encoded-sRGB source-over differs: maximum code error {error}, expected {expected} within 1")
    return {"backgroundRGB": background_rgb, "blackAlpha": "100/255", "expectedRGB": expected,
            "maximumCodeError": error, "codeTolerance": 1, "region": [0.05, 0.9, 0.1, 0.05], "outsideGlyphAndShadow": True}


def style_negatives(style):
    changes = {
        "missingShadow": lambda value: value.pop("shadow"),
        "wrongShadowStroke": lambda value: value["shadow"].update(strokeColor=value["shadow"]["color"]),
        "wrongShadowFill": lambda value: value["shadow"].update(color=value["shadow"]["strokeColor"]),
        "wrongShadowOffset": lambda value: value["shadow"].update(x=-16, y=30),
        "wrongOutlineWidth": lambda value: value["outline"].update(width=12),
        "missingOutline": lambda value: value.pop("outline"),
        "narrowOutline": lambda value: value["outline"].update(width=2),
        "shiftedCaption": lambda value: value.update(x=value["x"] + 32, y=value["y"] + 24),
        "wrongAlignment": lambda value: value.update(alignment="left"),
        "wrongAnchor": lambda value: value.update(anchor="center"),
        "wrongLineAdvance": lambda value: value.update(lineAdvance=value["lineAdvance"] + 40),
        "wrongGradientStart": lambda value: value["gradient"].update(startY=value["gradient"]["startY"] - 300),
        "wrongGradientProfile": lambda value: value["gradient"]["stops"].insert(1, {"location": 0.5, "color": value["gradient"]["stops"][-1]["color"]}),
    }
    result = {}
    for name, change in changes.items():
        result[name] = copy.deepcopy(style)
        change(result[name])
    return result


def style_comparisons(actual, expected, positive, negatives, layer, width, height):
    result = {}
    for name, wrong in negatives.items():
        selected = []
        for offset in offsets(width, height, (0, 0.55, 1, 0.45)):
            pixel = offset // 3
            x, y = pixel % width, pixel // width
            if not (2 <= x < width - 2 and 2 <= y < height - 2):
                continue
            stable = all(layer[pixel * 4:pixel * 4 + 4] == layer[(pixel + dy * width + dx) * 4:(pixel + dy * width + dx) * 4 + 4]
                         for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)])
            if stable and max(abs(expected[offset + c] - wrong[offset + c]) for c in range(3)) >= 24:
                selected.append(offset)
        require(len(selected) >= 12, f"Styled caption control is not independently distinguishable: {name}")
        result[name] = calibrated_comparison(actual, expected, positive, {name: wrong}, selected)
    return result


def check_styled_caption(actual, background, text, style, width, height):
    expected, layer = styled_reference(background, text, style, width, height)
    negatives = {name: styled_reference(background, text, value, width, height)[0] for name, value in style_negatives(style).items()
                 if name != "wrongLineAdvance" or "\n" in text}
    return style_comparisons(actual, expected, codec_control(expected, width, height), negatives, layer, width, height)


def check_caption_placement(actual, background, text, style, width, height, bounds):
    canvas = PangoCanvas(width, height)
    try:
        layer = canvas.glyph_layer(text, style)
    finally:
        canvas.close()
    expected = {(index % width, index // width) for index, alpha in enumerate(layer[3::4])
                if alpha == 255 and min(layer[index * 4:index * 4 + 3]) >= 192}
    observed = ink_mask(actual, width, height, bounds, background)
    def boxes(points):
        rows = sorted({y for _, y in points})
        require(rows, "Absolute caption ink is missing")
        intervals = [[rows[0], rows[0]]]
        for y in rows[1:]:
            if y - intervals[-1][1] > max(2, math.ceil(style["fontSize"] * width / style["canvasWidth"] * 0.15)):
                intervals.append([y, y])
            else:
                intervals[-1][1] = y
        return [(min(x for x, y in points if start <= y <= end), start,
                 max(x for x, y in points if start <= y <= end), end) for start, end in intervals]
    expected_boxes, actual_boxes = boxes(expected), boxes(observed)
    require(len(expected_boxes) == len(actual_boxes) == len(text.split("\n")), "Absolute caption line count differs")
    require(all(abs(a - b) <= 2 for left, right in zip(expected_boxes, actual_boxes) for a, b in zip(left, right)),
            f"Absolute caption placement differs: {actual_boxes} != {expected_boxes}")
    return {"expectedInkBoxes": expected_boxes, "actualInkBoxes": actual_boxes, "edgeTolerancePixels": 2,
            "alignment": style["alignment"], "anchor": style["anchor"], "lineAdvance": style["lineAdvance"], "fittedTranslation": False}
