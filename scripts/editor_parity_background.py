import json

from editor_acceptance_contracts import require
from editor_parity_fixtures import checksum, command, ffmpeg, write_json
from editor_parity_pixels import calibrated_comparison, codec_control, difference, offsets
from editor_parity_review import frame_pixels


def background_source(path):
    width, height = 1024, 576
    data = bytearray()
    for y in range(height):
        for x in range(width):
            color = (12, 12, 12)
            if 320 <= x < 350:
                color = (248, 248, 248)
            elif 440 <= x <= 640:
                color = (240, 32, 48) if (x // 24 + y // 24) % 2 else (16, 224, 240)
            data.extend(color)
    ffmpeg("-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", "1024x576", "-i", "pipe:0",
           "-frames:v", "1", "-update", "1", path, data=bytes(data))


def background_reference(source, mode):
    fill = "scale=854:480:flags=lanczos"
    crop = "crop=270:480:(iw-ow)/2:0"
    blur = "gblur=sigma=8.125:steps=3"
    if mode == "encodedCropFirst":
        filters = f"{fill},{crop},{blur}"
    elif mode == "offCanvasBleed":
        filters = f"{fill},{blur},{crop}"
    else:
        require(mode == "linearBlur", "Unknown background reference mode")
        decode = "if(lte(val/maxval,0.04045),val/12.92,pow((val/maxval+0.055)/1.055,2.4)*maxval)"
        encode = "if(lte(val/maxval,0.0031308),val*12.92,(1.055*pow(val/maxval,1/2.4)-0.055)*maxval)"
        linearize = "lutrgb=" + ":".join(f"{channel}='{decode}'" for channel in "rgb")
        delinearize = "lutrgb=" + ":".join(f"{channel}='{encode}'" for channel in "rgb")
        filters = f"{fill},{crop},format=gbrp16le,{linearize},{blur},{delinearize},format=rgb24"
    return command(["ffmpeg", "-v", "error", "-i", source, "-vf", filters, "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"])


def background_controls(source):
    expected = background_reference(source, "encodedCropFirst")
    positive = codec_control(expected, 270, 480)
    negatives = {name: background_reference(source, name) for name in ("offCanvasBleed", "linearBlur")}
    selections = {}
    for name, wrong in negatives.items():
        area = (0, 0, 0.12, 1) if name == "offCanvasBleed" else (0.28, 0, 0.7, 1)
        candidates = offsets(270, 480, area, [(0, 0.32, 1, 0.36)])
        selections[name] = [index for index in candidates if max(abs(wrong[index + c] - expected[index + c]) for c in range(3)) >= 20]
        require(len(selections[name]) >= 100, f"Background fixture cannot resolve {name}")
        calibrated_comparison(positive, expected, positive, {name: wrong}, selections[name])
        try:
            calibrated_comparison(wrong, expected, positive, {name: wrong}, selections[name])
        except AssertionError as error:
            require("Native pixels differ" in str(error), str(error))
        else:
            raise AssertionError(f"Background negative escaped: {name}")
    return expected, positive, negatives, selections


def background_probe(edit, workspace):
    directory = workspace / "background-stress"
    directory.mkdir()
    source, project = directory / "synthetic-offcanvas.png", directory / "background.openscreen"
    background_source(source)
    digest = checksum(source)
    expected, positive, negatives, selections = background_controls(source)
    edit("create", project, "--title", "Synthetic off-canvas and transfer blur", "--json")
    operations = [
        {"videoSettings": {"settings": {"width": 1080, "height": 1920, "frameRateNumerator": 60, "frameRateDenominator": 1, "colorSpace": "rec709"}}},
        {"canvas": {"aspectRatio": "9:16", "padding": 0, "backgroundColor": "#000000"}},
        {"addStill": {"path": str(source), "name": "offcanvas", "duration": 1}},
        {"visualEffects": {"clipID": "offcanvas", "effects": {"framing": "fullWidth", "background": {"blurRadius": 32.5},
                                                                 "gradingMode": "ffmpeg709", "brightness": 0, "contrast": 1, "saturation": 1}}},
    ]
    edit("apply", project, "--plan", "-", "--overwrite", "--json", stdin=json.dumps({"version": 1, "operations": operations}))
    project_digest = checksum(project)
    actual = frame_pixels(edit, project, 0, directory / "native.png", (270, 480))
    checks = {}
    for name, wrong in negatives.items():
        measured = difference(actual, expected, selections[name])
        try:
            comparison = calibrated_comparison(actual, expected, positive, {name: wrong}, selections[name])
            require(measured["meanAbsoluteError"] <= 8 and measured["p95AbsoluteError"] <= 24,
                    "Background exceeds absolute MAE 8 or p95 24")
            checks[name] = {"passed": True, **comparison}
        except AssertionError as error:
            checks[name] = {"passed": False, **measured, "error": str(error)}
    require(checksum(source) == digest and checksum(project) == project_digest, "Background probe modified protected artifacts")
    report = {"passed": all(value["passed"] for value in checks.values()), "productAcceptance": False,
              "backgroundRegions": checks, "independentNegativeControlsRejected": 2, "sourceSHA256": digest,
              "blurSpace": "encodedSRGB", "cropBeforeBlur": True}
    report["absoluteErrorBudgets"] = {"mean": 8, "p95": 24}
    write_json(directory / "background-probe.json", report)
    return report
