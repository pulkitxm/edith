import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, features, __version__

parser = argparse.ArgumentParser()
parser.add_argument("--font", default="/System/Library/Fonts/Supplemental/Arial Bold Italic.ttf")
parser.add_argument("--output", default="scripts/fixtures/caption-reference")
args = parser.parse_args()
output = Path(args.output)
output.mkdir(parents=True, exist_ok=True)
cases = []
for size in [104, 112]:
    font = ImageFont.truetype(args.font, size, layout_engine=ImageFont.Layout.BASIC)
    for name, text in [("one", "fj"), ("two", "SYNTHETIC\nCAPTION"), ("pairs", "AVATAR fj")]:
        image = Image.new("L", (2160, 3840))
        draw = ImageDraw.Draw(image)
        for index, line in enumerate(text.split("\n")):
            box = draw.textbbox((0, 0), line, font=font)
            x = (2160 - box[2] + box[0]) / 2
            draw.text((x, 2780 + 150 * index), line, font=font, fill=255)
        filename = f"{name}-{size}.png"
        image.save(output / filename)
        cases.append({"file": filename, "text": text, "size": size,
                      "bounds": image.point(lambda pixel: 255 if pixel >= 128 else 0).getbbox()})
manifest = {"pillow": __version__, "freetype": features.version("freetype2"),
            "layout": "BASIC", "fontSHA256": hashlib.sha256(Path(args.font).read_bytes()).hexdigest(),
            "cases": cases}
(output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
