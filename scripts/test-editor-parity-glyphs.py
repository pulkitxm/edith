import argparse
import json
import pathlib
import subprocess
import sys

from editor_acceptance_contracts import require
from editor_parity_fixtures import write_json
from editor_parity_glyphs import check_caption_identity, glyph_control_canvas, reference_caption_glyphs, reference_glyphs
from editor_parity_adapters import caption_style, CAPTION_BOUNDS
from editor_parity_pixels import codec_control


def rejects(operation, message):
    try:
        operation()
    except AssertionError as error:
        require(message in str(error), f"Unexpected caption negative-control failure: {error}")
    else:
        raise AssertionError("Caption negative control unexpectedly passed")


def main():
    parser = argparse.ArgumentParser(description="Independent exact-font caption identity controls using installed Pango")
    parser.add_argument("--workspace", required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    workspace = arguments.workspace.absolute()
    require(not workspace.exists(), "Caption control workspace must not already exist")
    workspace.mkdir(parents=True)
    width, height, top, advance = 1600, 400, 40, 150
    bounds, background = (0, 0, 1, 1), bytes(width * height * 3)
    reports = []
    for index, (text, size) in enumerate([("Amber Harbor", 104), ("Amber Harbor", 112), ("Amber Harbor\nCobalt Meadow", 104)]):
        reference = reference_glyphs(text, "Arial", "Bold Italic", size, workspace / f"reference-{index}")
        image = glyph_control_canvas(reference, width, height, top, advance)
        positive = codec_control(image, width, height)
        reports.append(check_caption_identity(positive, positive, background, width, height, bounds, reference))
    single = reference_glyphs("Amber Harbor", "Arial", "Bold Italic", 104, workspace / "one-line-control")
    wrong_font = reference_glyphs(reference["text"], "Courier New", "Bold Italic", 104, workspace / "wrong-font-control")
    wrong_text = reference_glyphs("Amber Harobr\nCobalt Meadow", "Arial", "Bold Italic", 104, workspace / "wrong-text-control")
    wrong_size = reference_glyphs(reference["text"], "Arial", "Bold Italic", 112, workspace / "wrong-size-control")
    for control, message in [(single, "line count"), (wrong_font, "font bounds"), (wrong_text, "glyph identity"), (wrong_size, "font bounds")]:
        image = glyph_control_canvas(control, width, height, top, advance)
        rejects(lambda: check_caption_identity(image, positive, background, width, height, bounds, reference), message)
    scaled = reference_caption_glyphs("Amber Lantern 01", caption_style(104), (540, 960), workspace / "scaled-reference")
    require(scaled["fontSize"] == 26 and scaled["referenceFontSize"] == 104
            and scaled["referenceCanvas"] == [2160, 3840], "Caption reference lost its declared canvas metrics")
    scaled_control = glyph_control_canvas(scaled, 540, 960, 700, 38)
    encoded = codec_control(scaled_control, 540, 960)
    scaled_report = check_caption_identity(encoded, encoded, bytes(540 * 960 * 3), 540, 960, CAPTION_BOUNDS, scaled)
    wrong = reference_caption_glyphs("Amber Lantner 01", caption_style(104), (540, 960), workspace / "scaled-wrong-text")
    rejects(lambda: check_caption_identity(glyph_control_canvas(wrong, 540, 960, 700, 38), encoded,
                                          bytes(540 * 960 * 3), 540, 960, CAPTION_BOUNDS, scaled), "glyph identity")
    result = {"productAcceptance": False, "independentGlyphControls": reports, "negativeControlsRejected": 4,
               "explicitLineCountVerified": True, "wrongFontRejected": True, "wrongGlyphOrderRejected": True, "wrongSizeRejected": True,
               "declaredCanvasScaling": scaled_report, "scaledWrongGlyphOrderRejected": True}
    write_json(workspace / "glyph-controls.json", result)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
