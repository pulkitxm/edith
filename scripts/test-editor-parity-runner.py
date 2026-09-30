import argparse
import json
import os
import pathlib
import subprocess
import sys
import uuid

from editor_acceptance_contracts import require
from editor_parity_adapters import aac_passthrough, caption_operations, lifecycle, master_project
from editor_parity_checks import check_captions, check_project, protected_snapshot, verify_artifacts
from editor_parity_cli import REQUIRED_GROUPS, base_operations, discover, exercise_transactions, invoke, publish_result
from editor_parity_finish import caption_review, delivery
from editor_parity_fixtures import checksum, verify, write_json
from editor_parity_motion import check_motion_plan, visual_operations
from editor_parity_review import stress_grading, visual_review
from editor_parity_style_probe import styled_pixel_probe


def main():
    parser = argparse.ArgumentParser(description="Complete isolated synthetic native editor parity acceptance")
    parser.add_argument("--ed", required=True, type=pathlib.Path)
    parser.add_argument("--fixture", required=True, type=pathlib.Path)
    parser.add_argument("--workspace", required=True, type=pathlib.Path)
    parser.add_argument("--runtime-env", type=pathlib.Path)
    parser.add_argument("--mode", choices=["quick", "full"], default="quick")
    parser.add_argument("--visual-only", action="store_true")
    parser.add_argument("--quick-result", type=pathlib.Path)
    args = parser.parse_args()
    require(not args.visual_only or args.mode == "quick", "Visual-only scope cannot publish full acceptance")
    workspace = args.workspace.absolute()
    require(not workspace.exists() and not workspace.is_symlink(), "Runner workspace must not already exist")
    fixture, ed = args.fixture.resolve(strict=True), args.ed.resolve(strict=True)
    binary = checksum(ed)
    verify(fixture)
    manifest = json.loads((fixture / "parity-manifest.json").read_text())
    protected = protected_snapshot(fixture, manifest)
    if args.mode == "full":
        require(args.quick_result and args.runtime_env, "Full acceptance requires --quick-result and the matching app's --runtime-env")
        quick = json.loads(args.quick_result.read_text())
        require(quick["mode"] == "quick" and quick["syntheticAcceptance"] is True and set(quick["groups"]) == REQUIRED_GROUPS
                and quick["groups"]["protectedSources"]["binarySHA256"] == binary
                and quick["groups"]["protectedSources"]["fixtureManifestSHA256"] == protected["parity-manifest.json"],
                "Full acceptance requires a completed quick run of this exact binary and fixture")
    workspace.mkdir(parents=True)
    runtime = json.loads(args.runtime_env.read_text()) if args.runtime_env else {
        "EDITH_DATA_ROOT": str(workspace / "runtime"), "EDITH_SHARED_DEFAULTS_SUITE": f"com.pulkit.edith.parity.{uuid.uuid4().hex}"}
    require(set(runtime) <= {"EDITH_DATA_ROOT", "EDITH_SHARED_DEFAULTS_SUITE"} and pathlib.Path(runtime["EDITH_DATA_ROOT"]).is_absolute(),
            "Runtime environment must declare an isolated absolute data root and optional matching defaults suite")
    require(not pathlib.Path(runtime["EDITH_DATA_ROOT"]).resolve().is_relative_to(fixture), "Runtime writes must stay outside protected fixtures")
    environment = {**os.environ, **runtime}
    write_json(workspace / "runtime-environment.json", runtime)

    def edit(*arguments, **options):
        return invoke(ed, *arguments, environment=environment, **options)

    dimensions = (540, 960) if args.mode == "quick" else (2160, 3840)
    operations = base_operations(manifest, dimensions) + visual_operations(manifest, dimensions)
    required = {name for operation in operations for name in operation}
    if not args.visual_only:
        required |= {"outputCaption", "captionStyle"}
    schemas = discover(ed, workspace, required, environment)
    effects = schemas["visualEffects"]["properties"]["visualEffects"]["properties"]["effects"]["properties"]
    require("ffmpeg709" in effects["gradingMode"]["enum"], "grading_mode_required: integrated FFmpeg-compatible grading is unavailable")
    captions, styles = ([], {}) if args.visual_only else caption_operations(manifest, schemas)
    if not args.visual_only:
        health = edit("audio", "health", "--json")
        require(health["available"] is True, "audio_mastering_required: integrated FFmpeg loudnorm is unavailable")
    project = workspace / "visual.openscreen"
    groups = {"cliTransactions": exercise_transactions(ed, project, {"version": 1, "operations": operations}, fixture, workspace, environment)}
    shown = edit("show", project, "--json")
    groups["editableProject"] = check_project(shown, manifest, fixture, dimensions)
    motion_plan = check_motion_plan(shown, manifest)
    pixels, motion, review = visual_review(edit, project, workspace, fixture, manifest)
    pixels["grading"] = stress_grading(edit, project, workspace, fixture, manifest, dimensions)
    groups.update(independentPixels=pixels, sourceTimingAndMotion={**motion_plan, **motion}, immediateReview=review)
    if args.visual_only:
        groups["nativeLifecycle"] = lifecycle(edit, ed, project, environment, False)
        require(protected_snapshot(fixture, manifest) == protected and checksum(ed) == binary, "Protected originals or binary changed during preflight")
        groups["protectedSources"] = {"binarySHA256": binary, "fixtureManifestSHA256": protected["parity-manifest.json"],
                                      "originalsAndBaselinesUnchanged": True, "protectedFiles": len(protected)}
        result = {"productAcceptance": False, "fullDeliveryAcceptance": False, "groups": groups,
                  "pendingGroups": ["styledCaptions", "masteredAudio", "aacPacketPassthrough", "matchingNativeAppOpen", "fullDelivery"]}
        write_json(workspace / "visual-preflight.json", result)
        print(json.dumps({"productAcceptance": False, "cliTransactions": 5, "originals": 47, "photoMotionCases": 42,
                          "nonzeroTrimVideos": 5, "gradingPhotos": 18, "headlessRegistration": True,
                          "pendingGroups": result["pendingGroups"]}, indent=2))
        return
    styled = workspace / "styled.openscreen"
    edit("apply", project, "--plan", "-", "--output", styled, "--json", stdin=json.dumps({"version": 1, "operations": captions}))
    groups["captions"] = caption_review(edit, project, styled, workspace, manifest, styles, dimensions)
    groups["captions"]["styledPixels"] = styled_pixel_probe(edit, workspace, schemas)
    mastered, groups["masteredAudio"], groups["editableProject"], reference, codec, artifacts = master_project(
        edit, styled, workspace, manifest, fixture, dimensions)
    artifacts.update({project: checksum(project), ed: binary, **{fixture / path: digest for path, digest in protected.items()}})
    check_captions(edit("captions", "list", mastered, "--json"), manifest, styles)
    check_motion_plan(edit("show", mastered, "--json"), manifest)
    groups["aacPacketPassthrough"] = aac_passthrough(edit, workspace, fixture, manifest)
    try:
        groups["nativeLifecycle"] = lifecycle(edit, ed, mastered, environment, args.mode == "full")
    finally:
        groups["masteredAudio"]["artifactStability"].append(verify_artifacts(artifacts, "after lifecycle calls"))
    output = workspace / "delivery.mp4"
    groups["delivery"] = delivery(edit, mastered, project, output, workspace, fixture, manifest, dimensions, reference, codec)
    require(protected_snapshot(fixture, manifest) == protected and checksum(ed) == binary, "Protected originals or CLI binary changed during acceptance")
    groups["protectedSources"] = {"binarySHA256": binary, "fixtureManifestSHA256": protected["parity-manifest.json"],
                                  "originalsAndBaselinesUnchanged": True, "protectedFiles": len(protected)}
    groups["masteredAudio"]["artifactStability"].append(verify_artifacts(artifacts, "immediately before publication"))
    groups["masteredAudio"]["provenanceVerified"] = True
    result = publish_result(workspace, groups, args.mode)
    print(json.dumps({"mode": args.mode, "fullDeliveryAcceptance": result["fullDeliveryAcceptance"],
                      "completedGroups": sorted(groups), "delivery": str(output)}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
