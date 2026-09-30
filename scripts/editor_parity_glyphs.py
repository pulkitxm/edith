import math
import pathlib

from editor_acceptance_contracts import require
from editor_parity_fixtures import checksum, command, probe
from editor_parity_pixels import image_pixels


def ink_mask(pixels, width, height, bounds, background=None):
    left, top, extent_x, extent_y = bounds
    return {(x, y) for y in range(math.ceil(top * height), math.floor((top + extent_y) * height))
            for x in range(math.ceil(left * width), math.floor((left + extent_x) * width))
            if min(pixels[(y * width + x) * 3:(y * width + x) * 3 + 3]) >= 192
            and (background is None or max(pixels[(y * width + x) * 3 + channel] - background[(y * width + x) * 3 + channel]
                                           for channel in range(3)) >= 32)}


def cropped_mask(ink):
    require(ink, "Caption glyph mask is empty")
    left, top = min(x for x, _ in ink), min(y for _, y in ink)
    width, height = max(x for x, _ in ink) - left + 1, max(y for _, y in ink) - top + 1
    return {"width": width, "height": height, "ink": {(x - left, y - top) for x, y in ink}}


def split_lines(ink, font_size):
    rows = sorted({y for _, y in ink})
    require(rows, "Caption glyph mask is empty")
    ranges = [[rows[0], rows[0]]]
    for y in rows[1:]:
        if y - ranges[-1][1] > max(2, math.ceil(font_size * 0.15)):
            ranges.append([y, y])
        else:
            ranges[-1][1] = y
    return [cropped_mask({(x, y) for x, y in ink if start <= y <= end}) for start, end in ranges]


def reference_glyphs(text, family, style, size, directory):
    require(text and all(line.strip() for line in text.split("\n")), "Reference captions must contain nonempty explicit lines")
    match = command(["fc-match", "-f", "%{family}\n%{style}\n%{file}\n", f"{family}:style={style}"]).decode().splitlines()
    require(len(match) == 3 and family.casefold() in {name.casefold() for name in match[0].split(",")}
            and style.casefold() in {name.casefold() for name in match[1].split(",")}, "Independent caption font unexpectedly fell back")
    directory.mkdir()
    lines = []
    for index, text_line in enumerate(text.split("\n")):
        image = directory / f"line-{index}.png"
        command(["pango-view", "--no-display", "--backend=cairo", "--pixels", "--margin=8", "--hinting=none",
                 "--hint-metrics=off", "--antialias=gray", "--subpixel-positions", "--background=#000000", "--foreground=#ffffff",
                 f"--font={family} {style} {size}", f"--text={text_line}", f"--output={image}"])
        stream = probe(image)["streams"][0]
        width, height = stream["width"], stream["height"]
        data = image_pixels(image, width, height)
        lines.append(cropped_mask(ink_mask(data, width, height, (0, 0, 1, 1))))
    return {"fontFamily": family, "fontStyle": style, "fontSize": size,
            "fontFileSHA256": checksum(pathlib.Path(match[2])), "text": text, "lines": lines}


def glyph_distance(actual, expected):
    require(abs(actual["width"] - expected["width"]) <= 2 and abs(actual["height"] - expected["height"]) <= 2,
            "Caption font bounds differ from the independent exact-font reference")
    expected_ink = expected["ink"]
    expected_edge_band = {(x + dx, y + dy) for x, y in expected_ink for dx in (-1, 0, 1) for dy in (-1, 0, 1)}
    errors = []
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            actual_ink = {(x + dx, y + dy) for x, y in actual["ink"]}
            actual_edge_band = {(x + ax, y + ay) for x, y in actual_ink for ax in (-1, 0, 1) for ay in (-1, 0, 1)}
            errors.append((len(actual_ink - expected_edge_band) + len(expected_ink - actual_edge_band))
                          / (len(actual_ink) + len(expected_ink)))
    return min(errors)


def check_caption_identity(actual, positive_control, background, width, height, bounds, reference):
    require(len(actual) == len(positive_control) == len(background) == width * height * 3, "Invalid caption identity image dimensions")
    observed = split_lines(ink_mask(actual, width, height, bounds, background), reference["fontSize"])
    control = split_lines(ink_mask(positive_control, width, height, bounds, background), reference["fontSize"])
    require(len(observed) == len(control) == len(reference["lines"]), "Caption rendered line count differs from its explicit text")
    reports = []
    for line, positive, expected in zip(observed, control, reference["lines"]):
        calibration = glyph_distance(positive, expected)
        tolerance = max(2 / (len(positive["ink"]) + len(expected["ink"])), 4 * calibration)
        require(tolerance <= 0.01, "Independent caption calibration cannot resolve stable glyph interiors")
        measured = glyph_distance(line, expected)
        require(measured <= tolerance, "Caption glyph identity differs from the independent exact-font reference")
        reports.append({"inkWidth": line["width"], "inkHeight": line["height"], "stableInteriorMismatch": measured,
                        "codecControlMismatch": calibration, "computedTolerance": tolerance})
    return {"fontFamily": reference["fontFamily"], "fontStyle": reference["fontStyle"], "fontSize": reference["fontSize"],
            "fontFileSHA256": reference["fontFileSHA256"], "explicitLineCount": len(observed), "lines": reports,
            "antialiasEdgeBandPixels": 1, "rescalingAllowed": False}


def glyph_control_canvas(reference, width, height, top, line_advance):
    data = bytearray(width * height * 3)
    for index, line in enumerate(reference["lines"]):
        left = (width - line["width"]) // 2
        y_offset = top + index * line_advance
        require(left >= 0 and y_offset + line["height"] <= height, "Reference glyphs do not fit the control canvas")
        for x, y in line["ink"]:
            offset = ((y + y_offset) * width + x + left) * 3
            data[offset:offset + 3] = b"\xff\xff\xff"
    return bytes(data)
