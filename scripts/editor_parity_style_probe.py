import json

from editor_acceptance_contracts import require
from editor_parity_adapters import CAPTION_BOUNDS, caption_operations
from editor_parity_checks import decoded_frames
from editor_parity_fixtures import checksum, ffmpeg
from editor_parity_review import frame_pixels
from editor_parity_style import check_caption_placement, check_styled_caption


def styled_pixel_probe(edit, workspace, schemas):
    directory = workspace / "styled-pixel-probe"
    directory.mkdir()
    source = directory / "synthetic-blue-card.png"
    ffmpeg("-f", "lavfi", "-i", "color=c=0x78a0c8:s=2160x3840", "-frames:v", "1", "-pix_fmt", "rgb24", source)
    source_digest = checksum(source)
    shots = [{"name": f"probe-{index}", "caption": text, "fontSize": size, "startFrame": index * 2, "endFrame": index * 2 + 2}
             for index, (text, size) in enumerate([("Amber Harbor", 104), ("Amber Harbor\nCobalt Meadow", 104), ("Amber Harbor", 112)])]
    base, styled = directory / "background.openscreen", directory / "styled.openscreen"
    edit("create", base, "--title", "Synthetic styled pixel control", "--json")
    operations = [{"videoSettings": {"settings": {"width": 2160, "height": 3840, "frameRateNumerator": 60, "frameRateDenominator": 1, "colorSpace": "rec709"}}}]
    operations += [{"addStill": {"path": str(source), "name": shot["name"], "duration": 2 / 60}} for shot in shots]
    edit("apply", base, "--plan", "-", "--overwrite", "--json", stdin=json.dumps({"version": 1, "operations": operations}))
    captions, styles = caption_operations({"shots": shots}, schemas)
    edit("apply", base, "--plan", "-", "--output", styled, "--json", stdin=json.dumps({"version": 1, "operations": captions}))
    before = {base: checksum(base), styled: checksum(styled)}
    delivery = directory / "styled.mp4"
    edit("render", styled, "--output", delivery, "--codec", "h264", "--bit-rate", "80000000", "--progress", "--json")
    checks = []
    for shot in shots:
        background = frame_pixels(edit, base, shot["startFrame"], directory / f"{shot['name']}-background.png", (2160, 3840))
        actual = frame_pixels(edit, styled, shot["startFrame"], directory / f"{shot['name']}-styled.png", (2160, 3840))
        encoded = decoded_frames(delivery, 2160, 3840, [shot["startFrame"]])[shot["startFrame"]]
        style = styles[shot["name"]]
        checks.append({"text": shot["caption"], "fontSize": shot["fontSize"],
                       "placement": check_caption_placement(actual, background, shot["caption"], style, 2160, 3840, CAPTION_BOUNDS),
                       "style": check_styled_caption(actual, background, shot["caption"], style, 2160, 3840),
                       "encodedStyle": check_styled_caption(encoded, background, shot["caption"], style, 2160, 3840),
                       "encodedPlacement": check_caption_placement(encoded, background, shot["caption"], style, 2160, 3840, CAPTION_BOUNDS)})
    require(checksum(source) == source_digest and all(checksum(path) == digest for path, digest in before.items()), "Styled probe changed protected inputs")
    return {"independentStyledCases": checks, "backgroundRGB": [120, 160, 200], "sourceSHA256": source_digest}
