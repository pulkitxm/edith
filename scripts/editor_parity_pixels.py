import math
import pathlib
import statistics
import struct
import tempfile

from editor_acceptance_contracts import require
from editor_parity_fixtures import command


def reference_pixels(source, width, height, framing="contain", blur=8, brightness=0, contrast=1, saturation=1,
                     background="blur", vertical_offset=0, source_crop=None, focal_x=0.5, focal_y=0.5):
    color = f"format=yuv444p,eq=brightness={brightness}:contrast={contrast}:saturation={saturation},format=rgb24"
    fill = (f"scale={width}:{height}:force_original_aspect_ratio=increase:flags=lanczos,"
            f"crop={width}:{height}:x=(iw-ow)*{focal_x}:y=(ih-oh)*{focal_y}")
    crop = ""
    if source_crop:
        crop = (f"crop=iw*{source_crop['width']}:ih*{source_crop['height']}:"
                f"iw*{source_crop['x']}:ih*{source_crop['y']},")
    if framing == "fill":
        graph = f"[0:v]{crop}{fill},{color}[result]"
    else:
        require(framing == "contain" and background in {"blur", "black"}, "Unsupported independent reference geometry")
        foreground = f"{crop}scale={width}:{height}:force_original_aspect_ratio=decrease:flags=lanczos"
        treatment = f"gblur=sigma={blur}:steps=3" if background == "blur" and blur > 0 else "null"
        if background == "black":
            treatment = "lutrgb=r=0:g=0:b=0"
        graph = (f"[0:v]split=2[background][foreground];[background]{fill},{treatment}[back];"
                 f"[foreground]{foreground}[front];[back][front]overlay=(W-w)/2:(H-h)/2+{vertical_offset}:format=rgb,{color}[result]")
    data = command(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-i", source, "-filter_complex", graph,
                    "-map", "[result]", "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"])
    require(len(data) == width * height * 3, "Independent reference has unexpected dimensions")
    return data


def has_png_profile(path):
    with path.open("rb") as stream:
        if stream.read(8) != b"\x89PNG\r\n\x1a\n":
            return False
        while header := stream.read(8):
            require(len(header) == 8, "Truncated PNG chunk header")
            length, kind = struct.unpack(">I4s", header)
            if kind == b"iCCP":
                return True
            if kind in {b"IDAT", b"IEND"}:
                return False
            stream.seek(length + 4, 1)
    return False


def decoded_image_pixels(path, width, height):
    data = command(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-i", path, "-vf",
                    f"scale={width}:{height}:flags=lanczos", "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"])
    require(len(data) == width * height * 3, "Review image has unexpected dimensions")
    return data


def image_pixels(path, width, height):
    if not has_png_profile(path):
        return decoded_image_pixels(path, width, height)
    root = pathlib.Path(tempfile.gettempdir()) / "opencode"
    root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="parity-icc-", dir=root) as temporary:
        normalized = pathlib.Path(temporary) / "srgb.png"
        command(["sips", "--matchTo", "/System/Library/ColorSync/Profiles/sRGB Profile.icc", path, "--out", normalized])
        return decoded_image_pixels(normalized, width, height)


def codec_control(pixels, width, height):
    encoded = command(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "rawvideo", "-pixel_format", "rgb24",
                       "-video_size", f"{width}x{height}", "-i", "pipe:0", "-frames:v", "1", "-c:v", "libx264", "-crf", "18",
                       "-pix_fmt", "yuv420p", "-f", "h264", "pipe:1"], pixels)
    return command(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "h264", "-i", "pipe:0", "-frames:v", "1",
                    "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"], encoded)


def offsets(width, height, rectangle=(0, 0, 1, 1), exclude=()):
    left, top, extent_x, extent_y = rectangle
    return [3 * (y * width + x) for y in range(math.ceil(top * height), math.floor((top + extent_y) * height), 2)
            for x in range(math.ceil(left * width), math.floor((left + extent_x) * width), 2)
            if not any(a <= x / width <= a + c and b <= y / height <= b + d for a, b, c, d in exclude)]


def difference(actual, expected, indices):
    require(len(actual) == len(expected) and indices, "Invalid independent pixel comparison")
    errors = [abs(actual[index + channel] - expected[index + channel]) for index in indices for channel in range(3)]
    errors.sort()
    return {"meanAbsoluteError": statistics.mean(errors), "p95AbsoluteError": errors[int((len(errors) - 1) * 0.95)],
            "maximumAbsoluteError": errors[-1], "sampledPixels": len(indices)}


def calibrated_comparison(actual, expected, positive, negatives, indices):
    positive_error = difference(positive, expected, indices)["meanAbsoluteError"]
    negative_errors = {name: difference(value, expected, indices)["meanAbsoluteError"] for name, value in negatives.items()}
    require(negative_errors and min(negative_errors.values()) > max(1, positive_error) * 3,
            f"Reference controls cannot distinguish the requested effect from an incorrect rendering: {negative_errors}")
    threshold = (positive_error + min(negative_errors.values())) / 2
    measured = difference(actual, expected, indices)
    require(measured["meanAbsoluteError"] <= threshold,
            f"Native pixels differ from the independent reference: {measured['meanAbsoluteError']:.3f} > {threshold:.3f}")
    return {**measured, "measuredCodecError": positive_error, "negativeControlErrors": negative_errors,
            "computedTolerance": threshold, "toleranceRule": "midpoint between independent codec error and closest invalid control"}


def color_patch_offsets(width, height, source_dimensions, crop, exclusion):
    crop = crop or {"x": 0, "y": 0, "width": 1, "height": 1}
    foreground_height = width * source_dimensions[1] * crop["height"] / (source_dimensions[0] * crop["width"])
    top = (height - foreground_height) / (2 * height)
    patches = [(0.35, 0.475, 0.3, 0.05), (0.25, 0.025, 0.5, 0.025), (0.25, 0.95, 0.5, 0.025),
               (0.015, 0.2, 0.03, 0.6), (0.955, 0.2, 0.03, 0.6)]
    indices = []
    for x, y, w, h in patches:
        if crop["x"] <= x and x + w <= crop["x"] + crop["width"] and crop["y"] <= y and y + h <= crop["y"] + crop["height"]:
            rectangle = ((x - crop["x"]) / crop["width"], top + (y - crop["y"]) * foreground_height / (crop["height"] * height),
                         w / crop["width"], h * foreground_height / (crop["height"] * height))
            indices.extend(offsets(width, height, rectangle, [exclusion]))
    require(indices, "No independent flat color patches remain visible")
    return sorted(set(indices))


def check_photo_pixels(actual, source, source_dimensions, width, height, blur, caption_bounds, color, source_crop=None):
    options = {"blur": blur, "source_crop": source_crop, **color}
    expected = reference_pixels(source, width, height, **options)
    positive = codec_control(expected, width, height)
    wrong_fill = reference_pixels(source, width, height, framing="fill", **options)
    wrong_black = reference_pixels(source, width, height, background="black", **options)
    wrong_shift = reference_pixels(source, width, height, vertical_offset=height * 0.08, **options)
    unblurred = reference_pixels(source, width, height, **{**options, "blur": 0})
    crop_ratio = source_crop["height"] / source_crop["width"] if source_crop else 1
    contain_height = width * source_dimensions[1] / source_dimensions[0] * crop_ratio
    require(contain_height < height, "Photo fixture must leave visible background above and below")
    top = (height - contain_height) / 2 / height
    foreground = offsets(width, height, (0.02, top + 0.01, 0.96, contain_height / height - 0.02), [caption_bounds])
    background = offsets(width, height, exclude=[(0, top - 0.015, 1, contain_height / height + 0.03), caption_bounds])
    result = {
        "centeredFullWidthOriginal": calibrated_comparison(actual, expected, positive,
                                                            {"fillCrop": wrong_fill, "shiftedForeground": wrong_shift}, foreground),
        "originalBlurBackground": calibrated_comparison(actual, expected, positive,
                                                         {"blackBackground": wrong_black, "missingBlur": unblurred}, background),
    }
    if color != {"brightness": 0, "contrast": 1, "saturation": 1}:
        identity = reference_pixels(source, width, height, blur=blur, source_crop=source_crop)
        patches = color_patch_offsets(width, height, source_dimensions, source_crop, caption_bounds)
        result["ffmpegEQ"] = calibrated_comparison(actual, expected, positive, {"missingColorEffect": identity}, patches)
    return result


def check_fill_pixels(actual, source, width, height, caption_bounds, color, focal_x=0.5, focal_y=0.5):
    expected = reference_pixels(source, width, height, framing="fill", focal_x=focal_x, focal_y=focal_y, **color)
    positive = codec_control(expected, width, height)
    wrong = {"containedInsteadOfFill": reference_pixels(source, width, height, framing="contain", **color)}
    if (focal_x, focal_y) != (0.5, 0.5):
        wrong["centeredInsteadOfFocalPoint"] = reference_pixels(source, width, height, framing="fill", **color)
    return calibrated_comparison(actual, expected, positive, wrong, offsets(width, height, exclude=[caption_bounds]))


def relative_luminance(pixel):
    linear = [channel / 255 / 12.92 if channel / 255 <= 0.04045 else ((channel / 255 + 0.055) / 1.055) ** 2.4 for channel in pixel]
    return sum(value * weight for value, weight in zip(linear, (0.2126, 0.7152, 0.0722)))


def check_caption_pixels(actual, reference, width, height, bounds, foreground=(255, 255, 255), background=(0, 0, 0)):
    require(len(actual) == len(reference) == width * height * 3, "Invalid caption image dimensions")
    left, top, extent_x, extent_y = bounds
    require(0 <= left < left + extent_x <= 1 and 0 <= top < top + extent_y <= 1, "Caption bounds leave the canvas")
    indices = offsets(width, height, bounds)
    changed = [index for index in indices if max(abs(actual[index + channel] - reference[index + channel]) for channel in range(3)) > 24]
    require(len(changed) >= len(indices) * 0.05, "Caption did not visibly occupy its expected bounds")
    ink = [index for index in indices if max(abs(actual[index + channel] - foreground[channel]) for channel in range(3)) < 24]
    backing = [index for index in indices if max(abs(actual[index + channel] - background[channel]) for channel in range(3)) < 24]
    require(len(ink) > 4 and len(backing) > len(ink), "Caption foreground or contrasting backing is missing")
    all_ink = [index for index in offsets(width, height)
               if max(abs(actual[index + channel] - foreground[channel]) for channel in range(3)) < 24
               and max(abs(reference[index + channel] - foreground[channel]) for channel in range(3)) >= 48]
    require(all_ink and all(left * width + 1 <= (index // 3) % width < (left + extent_x) * width - 1
                            and top * height + 1 <= index // (3 * width) < (top + extent_y) * height - 1 for index in all_ink),
            "Caption foreground touches or crosses its bounds")
    measured_foreground = [statistics.mean(actual[index + channel] for index in ink) for channel in range(3)]
    measured_background = [statistics.mean(actual[index + channel] for index in backing) for channel in range(3)]
    high, low = sorted((relative_luminance(measured_foreground), relative_luminance(measured_background)), reverse=True)
    contrast = (high + 0.05) / (low + 0.05)
    require(contrast >= 4.5, "Caption contrast is below 4.5:1")
    return {"foregroundPixels": len(ink), "backingPixels": len(backing), "changedPixels": len(changed),
            "measuredContrastRatio": contrast, "foregroundInsideBounds": True}
