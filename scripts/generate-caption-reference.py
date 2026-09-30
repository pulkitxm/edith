import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, features, __version__

parser = argparse.ArgumentParser()
parser.add_argument("--font", default="/System/Library/Fonts/Supplemental/Arial Bold Italic.ttf")
parser.add_argument("--output", default="scripts/fixtures/caption-reference")
args = parser.parse_args()
output = Path(args.output)
output.mkdir(parents=True, exist_ok=True)
cases = []
for size in [104, 112]:
    font = ImageFont.truetype(args.font, size, layout_engine=ImageFont.Layout.BASIC)
    for name, text in [("one", "fj"), ("two", "SYNTHETIC\nCAPTION"), ("pairs", "AVATAR fj"),
                       ("long", "firm little rivers drift far"),
                       ("mixed", "minimum rhythm from afar"),
                       ("long-two", "fifty little letters form\ntrim rivers from firm terrain")]:
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
subprocess.run(["bun", "x", "biome", "format", "--write", str(output / "manifest.json")], check=True)

font = ImageFont.truetype(args.font, 104, layout_engine=ImageFont.Layout.BASIC)
shadow = Image.new("RGBA", (2160, 3840))
foreground = Image.new("RGBA", shadow.size)
for index, line in enumerate(["SYNTHETIC", "CAPTION"]):
    box = font.getbbox(line)
    x = (2160 - box[2] + box[0]) / 2
    y = 2780 + 150 * index
    ImageDraw.Draw(shadow).text((x + 3, y + 7), line, font=font,
                               fill=(0, 0, 0, 230), stroke_width=7, stroke_fill=(0, 0, 0, 150))
    ImageDraw.Draw(foreground).text((x, y), line, font=font,
                                   fill=(255, 255, 255, 255), stroke_width=1, stroke_fill=(0, 0, 0, 70))
gradient = Image.new("RGBA", shadow.size)
draw = ImageDraw.Draw(gradient)
for y in range(3840):
    alpha = round(100 * max(0, min(1, (y - 2100) / 1500)))
    draw.line((0, y, 2159, y), fill=(0, 0, 0, alpha))
overlay = Image.alpha_composite(Image.alpha_composite(gradient, shadow.filter(ImageFilter.GaussianBlur(9))), foreground)
backgrounds = [("white", (255, 255, 255)), ("gray", (128, 128, 128)), ("color", (64, 160, 224))]
for name, color in backgrounds + [("tint", (64, 160, 224))]:
    if name == "tint":
        tinted = Image.new("RGBA", shadow.size, (51, 179, 102, 0))
        tinted.putalpha(gradient.getchannel("A"))
        overlay = Image.alpha_composite(Image.alpha_composite(tinted, shadow.filter(ImageFilter.GaussianBlur(9))), foreground)
    background = Image.new("RGBA", shadow.size, (*color, 255))
    background.save(output / f"background-{name}.png")
    Image.alpha_composite(background, overlay).save(output / f"composite-{name}.png")
swatch_front = Image.new("RGBA", (256, 18))
swatch_back = Image.new("RGBA", swatch_front.size)
for row, (_, background) in enumerate(backgrounds):
    for index, color in enumerate([(255, 255, 255), (0, 0, 0), (51, 179, 102)]):
        for alpha in range(256):
            for offset, opacity in [(0, 255), (9, 100)]:
                swatch_front.putpixel((alpha, row * 3 + index + offset), (*color, alpha))
                swatch_back.putpixel((alpha, row * 3 + index + offset), (*background, opacity))
swatch_front.save(output / "blend-foreground.png")
swatch_back.save(output / "blend-background.png")
Image.alpha_composite(swatch_back, swatch_front).save(output / "blend-reference.png")
