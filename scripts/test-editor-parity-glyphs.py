import argparse
import json
import pathlib
import subprocess
import sys

from editor_acceptance_contracts import require
from editor_parity_fixtures import write_json
from editor_parity_glyphs import check_caption_identity, glyph_control_canvas, reference_glyphs
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
    result = {"productAcceptance": False, "independentGlyphControls": reports, "negativeControlsRejected": 4,
              "explicitLineCountVerified": True, "wrongFontRejected": True, "wrongGlyphOrderRejected": True, "wrongSizeRejected": True}
    write_json(workspace / "glyph-controls.json", result)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
