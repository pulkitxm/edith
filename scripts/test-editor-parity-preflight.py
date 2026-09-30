import argparse
import json
import os
import pathlib
import subprocess
import sys
import uuid

from editor_acceptance_contracts import require
from editor_parity_checks import check_picture_samples, check_visual_project, picture_sample_frames, protected_snapshot
from editor_parity_cli import base_operations, discover, exercise_transactions, invoke
from editor_parity_fixtures import checksum, fixture_path, verify, write_json
from editor_parity_pixels import check_fill_pixels, check_photo_pixels, image_pixels


def main():
    parser = argparse.ArgumentParser(description="Native transaction and neutral-grade geometry preflight, not full parity acceptance")
    parser.add_argument("--ed", required=True, type=pathlib.Path)
    parser.add_argument("--fixture", required=True, type=pathlib.Path)
    parser.add_argument("--workspace", required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    workspace = arguments.workspace.absolute()
    require(not workspace.exists(), "Native preflight workspace must not already exist")
    fixture = arguments.fixture.resolve(strict=True)
    ed = arguments.ed.resolve(strict=True)
    binary_checksum = checksum(ed)
    workspace.mkdir(parents=True)
    runtime = {"EDITH_DATA_ROOT": str(workspace / "runtime"), "EDITH_SHARED_DEFAULTS_SUITE": f"com.pulkit.edith.parity.{uuid.uuid4().hex}"}
    environment = {**os.environ, **runtime}
    write_json(workspace / "runtime-environment.json", runtime)

    def edit(*args, **options):
        return invoke(ed, *args, environment=environment, **options)

    verify(fixture)
    manifest = json.loads((fixture / "parity-manifest.json").read_text())
    protected = protected_snapshot(fixture, manifest)
    dimensions, comparison = (540, 960), (180, 320)
    blur = 65 * dimensions[0] / manifest["width"]
    operations = base_operations(manifest, dimensions)
    for shot in manifest["shots"]:
        effects = {"framing": "fullWidth" if shot["framing"] == "contain" else "fill",
                   "focalX": shot["focalX"], "focalY": shot["focalY"]}
        if shot["framing"] == "contain":
            effects["background"] = {"blurRadius": blur}
        if "sourceCrop" in shot:
            operations.append({"crop": {"clipID": shot["name"], **shot["sourceCrop"]}})
        operations.append({"visualEffects": {"clipID": shot["name"], "effects": effects}})
    schema = discover(ed, workspace, {name for operation in operations for name in operation}, environment)
    visual = schema["visualEffects"]["properties"]["visualEffects"]["properties"]["effects"]["properties"]
    require("fullWidth" in visual["framing"]["enum"] and "background" in visual, "Native background contract is unavailable")
    project = workspace / "synthetic-preflight.openscreen"
    transactions = exercise_transactions(ed, project, {"version": 1, "operations": operations}, fixture, workspace, environment)
    shown = edit("show", project, "--json")
    project_result = check_visual_project(shown, manifest, fixture, dimensions)
    project_checksum = checksum(project)
    write_json(workspace / "transaction-checks.json", {"productAcceptance": False, "cliTransactions": transactions, "editableVisualProject": project_result})
    neutral = {"brightness": 0, "contrast": 1, "saturation": 1}
    photos = []
    for shot in (shot for shot in manifest["shots"] if shot["kind"] == "photo"):
        frame = shot["startFrame"] + shot["frames"] // 2
        output = workspace / f"review-{shot['name']}.png"
        report = edit("frame", project, "--frame", frame, "--output", output, "--json")
        require(report["frame"] == frame, "Immediate review selected the wrong output frame")
        actual = image_pixels(output, *comparison)
        source = fixture_path(fixture, shot["path"])
        if shot["framing"] == "contain":
            measured = check_photo_pixels(actual, source, (shot["width"], shot["height"]), *comparison,
                                          blur * comparison[0] / dimensions[0], (0, 0, 0, 0), neutral, shot.get("sourceCrop"))
        else:
            measured = check_fill_pixels(actual, source, *comparison, (0, 0, 0, 0), neutral, shot["focalX"], shot["focalY"])
        photos.append({"source": shot["name"], "framing": shot["framing"], "comparison": measured})
    pictures = {}
    for frame in picture_sample_frames(manifest):
        output = workspace / f"review-frame-{frame}.png"
        edit("frame", project, "--frame", frame, "--output", output, "--json")
        pictures[frame] = image_pixels(output, *comparison)
    signature_result = check_picture_samples(pictures, manifest, *comparison)
    require(protected_snapshot(fixture, manifest) == protected and checksum(project) == project_checksum,
            "Native preflight changed its protected originals, baseline exports, or editable project during review")
    require(checksum(ed) == binary_checksum, "Integrated binary changed during native preflight")
    result = {"productAcceptance": False, "fullDeliveryAcceptance": False, "syntheticNativePreflight": True,
              "binarySHA256": binary_checksum, "cliTransactions": transactions, "editableVisualProject": project_result,
              "unverifiedAudioEndDeltaSamples": (shown["audioTracks"][0]["endMs"] - manifest["frameCount"] * 1000 / 60) * 48,
              "neutralGradePhotoChecks": photos, "immediateReviewFrames": len(photos) + len(pictures),
              "pictureSignatures": signature_result, "sourceAndBaselineChecksumsUnchanged": True,
              "remainingGroups": ["styledCaptions", "masteredAudio", "aacPacketPassthrough", "nativeLifecycle", "gradedPixels", "sourceTimingAndMotion", "fullDelivery"]}
    write_json(workspace / "preflight-checks.json", result)
    print(json.dumps({"productAcceptance": False, "fullDeliveryAcceptance": False, "cliTransactionChecks": len(transactions),
                      "originalVisualSources": 47, "neutralGradePhotoChecks": len(photos), "immediateReviewFrames": result["immediateReviewFrames"],
                      "pictureSignatures": signature_result, "remainingGroups": result["remainingGroups"],
                      "sourceAndBaselineChecksumsUnchanged": True, "report": str(workspace / "preflight-checks.json")}, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
