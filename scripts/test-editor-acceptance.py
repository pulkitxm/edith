import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys

from editor_acceptance_captions import exercise_caption_preservation


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def run(arguments, report_path=None):
    result = subprocess.run([str(arg) for arg in arguments], capture_output=True, text=True, timeout=1800)
    if report_path and result.stdout:
        write_json(report_path, json.loads(result.stdout))
    require(result.returncode == 0, f"Command failed ({result.returncode}): {result.stderr}")
    return json.loads(result.stdout)


def normalized(value):
    identifiers = {}

    def visit(item):
        if isinstance(item, dict):
            return {key: visit(item[key]) for key in sorted(item) if key not in {"createdAt", "updatedAt"}}
        if isinstance(item, list):
            return [visit(child) for child in item]
        if isinstance(item, str) and re.fullmatch(r"[a-zA-Z_]*[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", item):
            return identifiers.setdefault(item, f"identity-{len(identifiers)}")
        return item

    return visit(value)


def check_sources(fixture, manifest):
    checksums = []
    for shot in manifest["shots"]:
        for kind in ("video", "still"):
            checksum = digest(fixture / shot[kind])
            require(checksum == shot[kind + "SHA256"], "Synthetic source was modified")
            if kind == "video":
                checksums.append(checksum)
    require(len(set(checksums)) == 45, "Expected 45 unique video source hashes")
    require(digest(fixture / manifest["music"]) == manifest["musicSHA256"], "Music source was modified")


def check_project(project, manifest):
    clips = project["timeline"]["clips"]
    assets = {asset["id"]: asset for asset in project["assets"]}
    require(len(clips) == 45, "Expected 45 clips")
    require(len({clip["id"] for clip in clips}) == 45, "Clip identities are duplicated")
    require(len({clip["assetId"] for clip in clips}) == 45, "Source identities are duplicated")
    position = 0
    for clip, shot in zip(clips, manifest["shots"]):
        source = assets[clip["assetId"]]
        require(pathlib.Path(source["originalPath"]).name == shot["video"], "Shot source or order changed")
        require(abs(clip["sourceStartSec"]) < 1e-8, "Unexpected source trim start")
        require(abs(clip["sourceEndSec"] - shot["frames"] / 60) < 1e-8, "Shot frame duration changed")
        require(abs(clip["timelineStartSec"] - position / 60) < 1e-8, "Timeline gap or overlap")
        position += shot["frames"]
    require(position == 1728, "Incorrect frame plan")
    audio = sorted(project["audioTracks"], key=lambda track: track["startMs"])
    require(audio and abs(audio[0]["startMs"]) < 1e-8, "Music must start at zero")
    end = 0
    for track in audio:
        require(abs(track["startMs"] - end) < 0.001, "Music gap or overlap")
        require(not track.get("muted", False), "Music is muted")
        require(pathlib.Path(assets[track["assetId"]]["originalPath"]).name == "music.wav", "Unexpected music source")
        require(abs(track.get("offsetMs", 0) - track["startMs"]) <= 1, "Music source position changed")
        end = track["endMs"]
    require(abs(end - 28800) < 0.001, "Music must cover the complete timeline")


def main():
    parser = argparse.ArgumentParser(description="Native synthetic acceptance for the bundled ed studio edit CLI")
    parser.add_argument("--workspace", required=True, type=pathlib.Path, help="New directory for synthetic artifacts")
    parser.add_argument("--ed", type=pathlib.Path, help="Actual development app Contents/MacOS/ed")
    parser.add_argument("--fixture", type=pathlib.Path, help="Reuse previously generated synthetic fixtures")
    parser.add_argument("--media-helper", type=pathlib.Path, help="Reuse the compiled native fixture helper")
    parser.add_argument("--fixture-only", action="store_true")
    parser.add_argument("--baseline", action="store_true", help="Exercise current rendering without exact delivery assertions")
    parser.add_argument("--contact-sheet", action="store_true", help="Verify a 45-shot contact sheet through the public CLI")
    parser.add_argument("--captions", action="store_true", help="Verify public caption timing across crop, speed, and reorder edits")
    parser.add_argument("--delivery-plan", type=pathlib.Path, help="Public v1 plan containing integrated delivery operations")
    args = parser.parse_args()
    workspace = args.workspace.absolute()
    require(not workspace.exists(), "Workspace must not already exist")
    require(args.fixture_only or args.ed is not None, "--ed is required for CLI acceptance")
    require(args.fixture_only or args.baseline or args.delivery_plan, "Full acceptance requires --delivery-plan")
    workspace.mkdir(parents=True)
    helper = args.media_helper.absolute() if args.media_helper else workspace / "editor-acceptance-media"
    if not args.media_helper:
        source = pathlib.Path(__file__).with_name("editor-acceptance-media.swift")
        cases = source.with_name("editor-acceptance-cases.swift")
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), str(cases), "-o", str(helper)], check=True, timeout=180)
    fixture = args.fixture.absolute() if args.fixture else workspace / "media"
    if not args.fixture:
        run([helper, "generate", fixture])
    manifest = json.loads((fixture / "manifest.json").read_text())
    check_sources(fixture, manifest)
    fixture_result = run([helper, "verify-fixture", fixture])
    write_json(workspace / "fixture-result.json", fixture_result)
    if args.fixture_only:
        print(json.dumps(fixture_result, indent=2, sort_keys=True))
        return
    ed = args.ed.absolute()
    require(ed.is_file(), "Bundled ed does not exist")

    def edit(*arguments):
        return run([ed, "studio", "edit", *arguments])

    schema = edit("schema")
    write_json(workspace / "schema.json", schema)
    definitions = schema["properties"]["operations"]["items"]["oneOf"]
    supported = {next(iter(item["properties"])) for item in definitions}
    operations = []
    for shot in manifest["shots"]:
        operations.extend([
            {"addMedia": {"path": str(fixture / shot["video"]), "name": shot["name"]}},
            {"trim": {"clipID": shot["name"], "start": 0, "end": shot["frames"] / 60}},
        ])
    operations.extend([
        {"canvas": {"aspectRatio": "9:16", "padding": 0, "backgroundColor": "#000000"}},
        {"addAudio": {"path": str(fixture / "music.wav"), "start": 0, "offset": 0}},
    ])
    if args.delivery_plan:
        delivery = json.loads(args.delivery_plan.read_text())
        require(delivery["version"] == 1, "Delivery plan must use public v1 operations")
        operations.extend(delivery["operations"])
    require(all(set(operation) <= supported for operation in operations), "Bundled CLI lacks required public operations")
    plan = {"version": 1, "operations": operations}
    plan_path = workspace / "plan.json"
    write_json(plan_path, plan)
    roundtrip_plan = workspace / "plan-roundtrip.json"
    write_json(roundtrip_plan, json.loads(plan_path.read_text()))
    require(plan_path.read_bytes() == roundtrip_plan.read_bytes(), "Plan JSON round trip changed bytes")
    snapshots = []
    for index in range(2):
        project = workspace / f"edit-{index}.openscreen"
        edit("create", project, "--title", "Synthetic acceptance", "--json")
        before = digest(project)
        dry_run = edit("apply", project, "--plan", plan_path, "--dry-run", "--json")
        require(dry_run["written"] is False and digest(project) == before, "Dry run modified the project")
        result = edit("apply", project, "--plan", plan_path if index == 0 else roundtrip_plan, "--overwrite", "--json")
        require(len(result["aliases"]) == 45, "Missing shot aliases")
        edit("validate", project, "--json")
        shown = edit("show", project, "--json")
        check_project(shown, manifest)
        snapshots.append(normalized(shown))
    require(snapshots[0] == snapshots[1], "Repeated plans produced different semantic projects")
    project = workspace / "edit-0.openscreen"
    noop = workspace / "noop.json"
    write_json(noop, {"version": 1, "operations": []})
    saved = workspace / "roundtrip.openscreen"
    edit("apply", project, "--plan", noop, "--output", saved, "--json")
    require(normalized(edit("show", saved, "--json")) == snapshots[0], "Project save round trip changed semantics")
    frame = workspace / "preview.png"
    render = workspace / "render.mp4"
    if args.contact_sheet:
        arguments = ["contact-sheet", saved, "--columns", "5", "--cell-width", "320",
                     "--output", workspace / "contact-sheet.png", "--json"]
        position = 0
        for shot in manifest["shots"]:
            arguments.extend(["--time", str((position + shot["frames"] / 2) / 60)])
            position += shot["frames"]
        sheet = edit(*arguments)
        require(len(sheet["frames"]) == 45, "Contact sheet did not select every shot")
        require(sheet["sha256"] == digest(workspace / "contact-sheet.png"), "Contact sheet checksum mismatch")
        checked = run([helper, "verify-contact-sheet", workspace / "contact-sheet.png"])
        write_json(workspace / "contact-sheet-result.json", checked)
    edit("frame", saved, "--time", "0.25", "--output", frame, "--json")
    edit("render", saved, "--output", render, "--json")
    check_sources(fixture, manifest)
    report = run([helper, "baseline" if args.baseline else "inspect", render, frame], workspace / "result.json")
    require(report["sha256"] == digest(render), "Independent output checksum mismatch")
    if args.captions:
        report["captionAcceptance"] = exercise_caption_preservation(edit, saved, workspace)
    report.update({"planRoundTrip": True, "projectRoundTrip": True, "sourcesUnchanged": True, "previewVerified": True})
    write_json(workspace / "result.json", report)
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
