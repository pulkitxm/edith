import json

from editor_acceptance_contracts import require
from editor_parity_style import check_encoded_blend_region, compose_encoded_style


def linear_light_black(background, alpha):
    def blend(code):
        encoded = code / 255
        linear = encoded / 12.92 if encoded <= 0.04045 else ((encoded + 0.055) / 1.055) ** 2.4
        linear *= 1 - alpha
        result = linear * 12.92 if linear <= 0.0031308 else 1.055 * linear ** (1 / 2.4) - 0.055
        return round(255 * result)
    return tuple(blend(code) for code in background)


def main():
    width, height = 64, 128
    transparent = bytes(width * height * 4)
    style = {"canvasHeight": 128, "gradient": {"startY": 16, "endY": 64, "stops": [
        {"location": 0, "color": {"red": 0, "green": 0, "blue": 0, "alpha": 0}},
        {"location": 1, "color": {"red": 0, "green": 0, "blue": 0, "alpha": 100 / 255}},
    ]}}
    cases = [((255, 255, 255), (155, 155, 155)), ((128, 128, 128), (78, 78, 78)), ((51, 153, 204), (31, 93, 124))]
    checks = []
    rejected = 0
    for background, expected in cases:
        actual = compose_encoded_style(bytes(background) * (width * height), transparent, style, width, height)
        require(tuple(actual[-3:]) == expected, "Encoded reference does not match independent integer alpha arithmetic")
        check = check_encoded_blend_region(actual, width, height, background)
        wrong = linear_light_black(background, 100 / 255)
        negatives = [wrong]
        if background == (255, 255, 255):
            negatives.append((204, 204, 204))
        if background == (128, 128, 128):
            negatives.append((101, 101, 101))
        for negative in negatives:
            try:
                check_encoded_blend_region(bytes(negative) * (width * height), width, height, background)
            except AssertionError as error:
                require("Encoded-sRGB source-over differs" in str(error), str(error))
                rejected += 1
            else:
                raise AssertionError("Linear-light composition escaped the encoded reference")
        checks.append({**check, "linearLightRGB": wrong, "oldNativeWhiteGap": 49 if background[0] == 255 else None})
    layers = [((255, 255, 255), (100, 100, 100, 100), (255, 255, 255)),
              ((0, 0, 0), (100, 100, 100, 100), (100, 100, 100)),
              ((255, 255, 255), (0, 0, 0, 100), (155, 155, 155)),
              ((128, 128, 128), (64, 64, 64, 128), (128, 128, 128)),
              ((120, 160, 200), (68, 51, 17, 85), (97, 158, 201))]
    for background, premultiplied_bgra, expected in layers:
        actual = compose_encoded_style(bytes(background), bytes(premultiplied_bgra), {}, 1, 1)
        require(tuple(actual) == expected, "Premultiplied outline, shadow, or antialiased edge did not use encoded source-over")
    print(json.dumps({"productAcceptance": False, "blendSpace": "encodedSRGB", "constantGradientRegions": checks,
                      "linearBlendNegativesRejected": rejected, "premultipliedLayerCases": len(layers)}, indent=2))


if __name__ == "__main__":
    main()
