from editor_acceptance_contracts import require
from editor_parity_motion import TARGET_GRADE, motion_reference
from editor_parity_pixels import codec_control, reference_pixels
from editor_parity_fixtures import command


NEUTRAL_GRADE = {"brightness": 0, "contrast": 1, "saturation": 1}
WRONG_GRADE = {"brightness": 0.06, "contrast": 1.12, "saturation": 1.15}


def target_references(source, shot, width, height, source_frame=None):
    def render(grade):
        if shot["kind"] == "video":
            frame = shot["sourceStartFrame"] if source_frame is None else source_frame
            raw = command(["ffmpeg", "-v", "error", "-i", source, "-vf", f"select=eq(n\\,{frame})", "-frames:v", "1",
                           "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"])
            filters = (f"scale={width}:{height}:force_original_aspect_ratio=increase:flags=lanczos,crop={width}:{height},"
                       "scale=in_range=full:out_range=limited:out_color_matrix=bt709,format=yuv444p,"
                       f"eq=brightness={grade['brightness']}:contrast={grade['contrast']}:saturation={grade['saturation']},"
                       "scale=in_range=limited:out_range=full:in_color_matrix=bt709,format=rgb24")
            return command(["ffmpeg", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{shot['width']}x{shot['height']}",
                            "-i", "pipe:0", "-vf", filters, "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"], raw)
        if shot["zoom"]:
            return motion_reference(source, shot, width, height, 0, grade)
        return reference_pixels(source, width, height, blur=65 * width / 2160, source_crop=shot.get("sourceCrop"), **grade)
    return render(TARGET_GRADE), {"neutral": render(NEUTRAL_GRADE), "stressInsteadOfTarget": render(WRONG_GRADE)}


def target_grade_measurement(actual, expected, positive, negatives, width, height, exclusion):
    require(all(len(value) == width * height * 3 for value in [actual, expected, positive, *negatives.values()]), "Invalid grade raster")
    selected = []
    left, top, span_x, span_y = exclusion
    for y in range(4, height - 4, 3):
        for x in range(4, width - 4, 3):
            if left <= x / width <= left + span_x and top <= y / height <= top + span_y:
                continue
            index = (y * width + x) * 3
            for channel in range(3):
                offset = index + channel
                signal = min(abs(value[offset] - expected[offset]) for value in negatives.values())
                if signal < 3 or abs(positive[offset] - expected[offset]) > (1 if signal >= 4 else 0):
                    continue
                if all(value[offset] == value[offset + 3 * (dy * width + dx)]
                       for value in [expected, *negatives.values()] for dx, dy in [(-3, 0), (3, 0), (0, -3), (0, 3)]):
                    selected.append(offset)
    require(len(selected) >= 32, "Target grade has insufficient independently resolved flat-color samples")
    def error(value):
        return sum(abs(value[index] - expected[index]) for index in selected) / len(selected)
    codec_error = error(positive)
    negative_errors = {name: error(value) for name, value in negatives.items()}
    rounding_budget = 0.5
    require(min(negative_errors.values()) > 3 * max(rounding_budget, codec_error), "Target-grade controls overlap the independent measurement budget")
    threshold = (max(rounding_budget, codec_error) + min(negative_errors.values())) / 2
    measured = error(actual)
    require(measured <= threshold, f"Target-grade pixels differ: {measured:.3f} > {threshold:.3f}")
    return {"target": TARGET_GRADE, "flatChannelSamples": len(selected), "measuredError": measured,
            "codecError": codec_error, "roundingBudget": rounding_budget, "negativeErrors": negative_errors,
            "computedTolerance": threshold, "selectionUsesActualPixels": False}


def check_target_grade(actual, source, shot, width, height, exclusion=(0, 0, 0, 0), source_frame=None):
    expected, negatives = target_references(source, shot, width, height, source_frame)
    return target_grade_measurement(actual, expected, codec_control(expected, width, height), negatives, width, height, exclusion)
