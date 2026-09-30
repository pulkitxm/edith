import json

from editor_acceptance_contracts import require
from editor_parity_checks import check_picture_samples, picture_sample_frames
from editor_parity_fixtures import checksum, fixture_path
from editor_parity_grade import check_target_grade
from editor_parity_motion import TARGET_GRADE, check_photo_motion, photo_sample_frames
from editor_parity_pixels import check_photo_pixels, image_pixels


def frame_pixels(edit, project, frame, output, dimensions):
    result = edit("frame", project, "--frame", frame, "--output", output, "--json")
    require(result["frame"] == frame and abs(result["time"] * 60 - frame) < 1e-7, "Immediate review selected an incorrect frame")
    return image_pixels(output, *dimensions)


def visual_review(edit, project, workspace, fixture, manifest):
    width, height = 270, 480
    before = checksum(project)
    review = workspace / "visual-review"
    review.mkdir()
    photos, geometry = [], []
    for shot in (shot for shot in manifest["shots"] if shot["kind"] == "photo"):
        source = fixture_path(fixture, shot["path"])
        frames = (0, shot["frames"] // 2, shot["frames"] - 1)
        actual = {offset: frame_pixels(edit, project, shot["startFrame"] + offset, review / f"{shot['name']}-{offset}.png", (width, height))
                  for offset in frames}
        photos.append({"source": shot["name"], "result": check_photo_motion(actual, source, shot, width, height),
                       "targetGrade": check_target_grade(actual[0], source, shot, width, height)})
        if shot["framing"] == "contain":
            comparison = check_photo_pixels(actual[0], source, (shot["width"], shot["height"]), width, height, 65 * width / 2160,
                                            (0, 0, 0, 0), TARGET_GRADE, shot.get("sourceCrop"), check_grade=False)
            geometry.append({"source": shot["name"], "comparison": comparison})
    pictures = {frame: frame_pixels(edit, project, frame, review / f"video-{frame}.png", (width, height)) for frame in picture_sample_frames(manifest)}
    picture_report = check_picture_samples(pictures, manifest, width, height)
    require(checksum(project) == before, "Immediate review changed its editable project")
    return {"photoGeometry": geometry, "motion": photos}, {"pictureSignatures": picture_report, "motionPhotos": 24,
            "staticPhotos": 18, "nonzeroSourceTrims": 5}, {"frames": len(photo_sample_frames(manifest)) + len(pictures), "projectPreserved": True}


def stress_grading(edit, project, workspace, fixture, manifest, dimensions):
    shown = edit("show", project, "--json")
    color = {"brightness": 0.06, "contrast": 1.12, "saturation": 1.15}
    shots = [(index, shot) for index, shot in enumerate(manifest["shots"]) if shot["framing"] == "contain"]
    operations = [{"visualEffects": {"clipID": shown["timeline"]["clips"][index]["id"], "effects": {
        "framing": "fullWidth", "gradingMode": "ffmpeg709", "background": {"blurRadius": 65 * dimensions[0] / 2160}, **color}}}
                  for index, _ in shots]
    stress = workspace / "grading-stress.openscreen"
    before = checksum(project)
    edit("apply", project, "--plan", "-", "--output", stress, "--json", stdin=json.dumps({"version": 1, "operations": operations}))
    comparisons = []
    for _, shot in shots:
        pixels = frame_pixels(edit, stress, shot["startFrame"], workspace / f"grade-{shot['name']}.png", (270, 480))
        comparison = check_photo_pixels(pixels, fixture_path(fixture, shot["path"]), (shot["width"], shot["height"]),
                                        270, 480, 65 / 8, (0, 0, 0, 0), color, shot.get("sourceCrop"))
        comparisons.append({"source": shot["name"], "comparison": comparison})
    index, shot = shots[1]
    wrong = workspace / "grading-native-control.openscreen"
    operation = {"visualEffects": {"clipID": shown["timeline"]["clips"][index]["id"], "effects": {
        "framing": "fullWidth", "gradingMode": "native", "background": {"blurRadius": 65 * dimensions[0] / 2160}, **color}}}
    edit("apply", project, "--plan", "-", "--output", wrong, "--json", stdin=json.dumps({"version": 1, "operations": [operation]}))
    pixels = frame_pixels(edit, wrong, shot["startFrame"], workspace / "wrong-grade.png", (270, 480))
    try:
        check_photo_pixels(pixels, fixture_path(fixture, shot["path"]), (shot["width"], shot["height"]), 270, 480, 65 / 8,
                           (0, 0, 0, 0), color, shot.get("sourceCrop"))
    except AssertionError as error:
        require("Native pixels differ" in str(error), "Wrong grading mode failed for an inconclusive reference control")
    else:
        raise AssertionError("Native grading was not distinguishable from the required FFmpeg-compatible mode")
    require(checksum(project) == before, "Grading controls changed the prepared project")
    return {"independentStressPhotos": comparisons, "nativeModeNegativeRejected": True, "targetModeRequired": "ffmpeg709"}
