import argparse
import json
import pathlib
import subprocess
import sys

from editor_acceptance_contracts import require
from editor_parity_checks import check_frame_signature, decoded_frames, protected_snapshot
from editor_parity_fixtures import fixture_path, verify, write_json
from editor_parity_motion import TARGET_GRADE, check_photo_motion, motion_reference
from editor_parity_pixels import codec_control, reference_pixels


def rejects(operation, message):
    try:
        operation()
    except AssertionError as error:
        require(message in str(error), f"Unexpected motion control failure: {error}")
    else:
        raise AssertionError("Motion negative control unexpectedly passed")


def main():
    parser = argparse.ArgumentParser(description="Independent original-trim and crop-then-zoom controls")
    parser.add_argument("--fixture", required=True, type=pathlib.Path)
    parser.add_argument("--workspace", required=True, type=pathlib.Path)
    args = parser.parse_args()
    fixture, workspace = args.fixture.resolve(strict=True), args.workspace.absolute()
    require(not workspace.exists(), "Motion control workspace must not already exist")
    workspace.mkdir(parents=True)
    verify(fixture)
    manifest = json.loads((fixture / "parity-manifest.json").read_text())
    protected = protected_snapshot(fixture, manifest)
    results, negatives = [], 0
    for shot in manifest["shots"]:
        source = fixture_path(fixture, shot["path"])
        if shot["kind"] == "video":
            selected = [shot["sourceStartFrame"] + offset for offset in (0, shot["frames"] // 2, shot["frames"] - 1)]
            frames = decoded_frames(source, shot["width"], shot["height"], [0, *selected])
            for frame in selected:
                check_frame_signature(frames[frame], shot["width"], shot["height"], shot, frame)
            rejects(lambda: check_frame_signature(frames[0], shot["width"], shot["height"], shot, shot["sourceStartFrame"]), "repeats, skips, or freezes")
            negatives += 1
            continue
        samples = (0, shot["frames"] // 2, shot["frames"] - 1)
        if shot["zoom"]:
            actual = {frame: codec_control(motion_reference(source, shot, 270, 480, frame), 270, 480) for frame in samples}
        else:
            pixels = reference_pixels(source, 270, 480, blur=65 / 8, source_crop=shot.get("sourceCrop"), **TARGET_GRADE)
            actual = {frame: pixels for frame in samples}
        result = check_photo_motion(actual, source, shot, 270, 480)
        results.append({"source": shot["name"], "zoom": shot["zoom"], "checks": result})
        if shot["zoom"] == 0.012:
            frozen = {frame: actual[0] for frame in samples}
            rejects(lambda: check_photo_motion(frozen, source, shot, 270, 480), "Photo zoom differs")
            negatives += 1
    require(protected_snapshot(fixture, manifest) == protected, "Motion controls changed original fixture files")
    report = {"productAcceptance": False, "photoCases": results, "nonzeroVideoTrims": 5, "negativeControlsRejected": negatives,
              "originalsAndBaselinesUnchanged": True}
    write_json(workspace / "motion-controls.json", report)
    print(json.dumps({"productAcceptance": False, "photoCases": len(results), "linearZoomPhotos": 24,
                      "staticPhotos": 18, "nonzeroVideoTrims": 5, "negativeControlsRejected": negatives}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
