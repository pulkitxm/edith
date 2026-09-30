import json

from editor_acceptance_contracts import require
from editor_parity_adapters import CAPTION_BOUNDS, caption_style
from editor_parity_pixels import codec_control
from editor_parity_style import check_caption_placement, style_comparisons, style_negatives, styled_reference


def main():
    text = "Amber Harbor\nCobalt Meadow"
    style = caption_style(104)
    width, height = 1080, 1920
    background = bytes((120, 160, 200)) * (width * height)
    expected, layer = styled_reference(background, text, style, width, height)
    positive = codec_control(expected, width, height)
    negatives = {name: styled_reference(background, text, value, width, height)[0] for name, value in style_negatives(style).items()}
    checks = style_comparisons(positive, expected, positive, negatives, layer, width, height)
    placement = check_caption_placement(positive, background, text, style, width, height, CAPTION_BOUNDS)
    for name, wrong in negatives.items():
        try:
            style_comparisons(wrong, expected, positive, {name: wrong}, layer, width, height)
        except AssertionError as error:
            require("Native pixels differ" in str(error), str(error))
        else:
            raise AssertionError(f"Styled reference failed to reject {name}")
    for name in ("shiftedCaption", "wrongAlignment", "wrongAnchor", "wrongLineAdvance"):
        try:
            check_caption_placement(negatives[name], background, text, style, width, height, CAPTION_BOUNDS)
        except AssertionError:
            pass
        else:
            raise AssertionError(f"Absolute placement failed to reject {name}")
    print(json.dumps({"productAcceptance": False, "negativeControlsRejected": list(checks), "placement": placement, "styledPixels": checks}, indent=2))


if __name__ == "__main__":
    main()
