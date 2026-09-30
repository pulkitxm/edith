import argparse
import json
from pathlib import Path

from PIL import Image, ImageCms, ImageFilter, ImageOps, __version__


def source(name):
    colors = [(255, 0, 0), (0, 255, 255), (0, 0, 255), (255, 255, 0)]
    rows = []
    for row in range(4):
        data = bytearray()
        for x in range(2400):
            if name == "step":
                color = (0, 0, 0) if x < 1200 else (255, 255, 255)
            elif name == "boundary":
                color = (255, 255, 255) if x < 120 or x >= 2280 else (0, 0, 0)
            else:
                color = colors[(x // 24 + row) % 4]
                if x < 120 or x >= 2280:
                    color = (255, 255, 255)
            data.extend(color)
        rows.append(bytes(data))
    return Image.frombytes("RGB", (2400, 3840), b"".join(rows[y // 40 % 4] for y in range(3840)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--images", type=Path)
    parser.add_argument("--p3-profile", type=Path, default=Path("/System/Library/ColorSync/Profiles/Display P3.icc"))
    args = parser.parse_args()
    if __version__ != "11.3.0":
        raise RuntimeError("Reference generation requires Pillow 11.3.0")
    srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB"))
    p3 = ImageCms.getOpenProfile(str(args.p3_profile))
    cases = []
    for name in ["step", "boundary", "texture", "p3"]:
        image = source(name)
        profile = p3 if name == "p3" else srgb
        if args.images:
            args.images.mkdir(parents=True, exist_ok=True)
            image.save(args.images / f"{name}.png", icc_profile=profile.tobytes())
        converted = ImageCms.profileToProfile(image, profile, srgb, outputMode="RGB")
        for divisor in [1, 4]:
            width, height = 2160 // divisor, 3840 // divisor
            reference = ImageOps.fit(converted, (width, height)).filter(ImageFilter.GaussianBlur(65 / divisor))
            xs = list(range(0, width, 90 // divisor)) + [width - 1]
            ys = list(range(0, height, 120 // divisor)) + [height - 1]
            rows = [[channel for x in xs for channel in reference.getpixel((x, y))] for y in ys]
            cases.append(dict(name=name, divisor=divisor, xs=xs, ys=ys, rows=rows))
            if args.images:
                reference.save(args.images / f"{name}-{divisor}-reference.png", icc_profile=srgb.tobytes())
    lines = ['{"pillow": "11.3.0", "radius": 65, "cases": [']
    for index, case in enumerate(cases):
        rows = case.pop("rows")
        lines.append(json.dumps(case)[:-1] + ', "rows": [')
        lines.extend(json.dumps(row) + ("," if i + 1 < len(rows) else "") for i, row in enumerate(rows))
        lines.append("]}" + ("," if index + 1 < len(cases) else ""))
    lines.append("]}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
