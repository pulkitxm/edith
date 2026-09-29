import argparse
import hashlib
import json
import pathlib
import subprocess
import sys

from editor_acceptance_contracts import original_still_source, verify_fixture_contracts


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(arguments):
    result = subprocess.run([str(value) for value in arguments], capture_output=True, text=True, timeout=1800)
    require(result.returncode == 0, f"Command failed ({result.returncode}): {result.stderr}")
    return json.loads(result.stdout)


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def settings(width, height, numerator=60, denominator=1):
    return {"width": width, "height": height, "frameRateNumerator": numerator,
            "frameRateDenominator": denominator, "colorSpace": "rec709"}


def main():
    parser = argparse.ArgumentParser(description="Headless original-still and cadence acceptance using public edit plans")
    parser.add_argument("--ed", required=True, type=pathlib.Path)
    parser.add_argument("--fixture", required=True, type=pathlib.Path)
    parser.add_argument("--workspace", required=True, type=pathlib.Path)
    parser.add_argument("--media-helper", required=True, type=pathlib.Path)
    parser.add_argument("--prepare-collection", action="store_true")
    args = parser.parse_args()
    workspace = args.workspace.resolve()
    require(not workspace.exists(), "Workspace must not exist")
    workspace.mkdir(parents=True)
    fixture = args.fixture.resolve(strict=True)
    manifest = json.loads((fixture / "extended-manifest.json").read_text())
    contracts = verify_fixture_contracts(fixture)
    cadence_hashes = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in fixture.glob("cadence-*.mov")}
    ed = args.ed.absolute()
    helper = args.media_helper.absolute()

    def edit(*arguments):
        return run([ed, "studio", "edit", *arguments])

    schema = edit("schema")
    write(workspace / "schema.json", schema)
    available = {next(iter(item["properties"])) for item in schema["properties"]["operations"]["items"]["oneOf"]}
    require({"addStill", "stillDuration", "videoSettings", "visualEffects"} <= available, "Required visual operations are missing")

    def create(name, operations):
        project = workspace / f"{name}.openscreen"
        plan = workspace / f"{name}.json"
        write(plan, {"version": 1, "operations": operations})
        edit("create", project, "--title", "Synthetic " + name, "--json")
        before = project.read_bytes()
        preview = edit("apply", project, "--plan", plan, "--dry-run", "--json")
        require(preview["written"] is False and before == project.read_bytes(), "Visual plan dry run changed project bytes")
        edit("apply", project, "--plan", plan, "--overwrite", "--json")
        edit("validate", project, "--json")
        return project

    identity_effects = {"framing": "fill", "focalX": 0.5, "focalY": 0.5, "exposure": 0,
                        "brightness": 0, "contrast": 1, "saturation": 1, "keyframes": []}
    original = fixture / manifest["originalStill"]
    still = create("original-detail", [
        {"videoSettings": {"settings": settings(3840, 2160)}},
        {"addStill": {"path": str(original), "name": "original", "duration": 1}},
        {"stillDuration": {"clipID": "original", "duration": 2}},
        {"visualEffects": {"clipID": "original", "effects": identity_effects}},
    ])
    shown = edit("show", still, "--json")
    require(shown["edithVideoSettings"] == settings(3840, 2160), "Explicit 4K settings changed")
    require(len(shown["assets"]) == len(shown["timeline"]["clips"]) == 1, "Still import created replacement assets")
    asset = shown["assets"][0]
    original_still_source(asset["originalPath"], original)
    require(shown["timeline"]["clips"][0]["sourceEndSec"] == 2, "Still duration was not extended")
    frame = workspace / "original-detail-frame.png"
    edit("frame", still, "--time", "1.5", "--output", frame, "--json")
    detail = run([helper, "verify-original-detail", frame])
    detail["originalSourceRetained"] = True
    write(workspace / "original-detail-result.json", detail)
    cadence_results = []
    for name, numerator, denominator in [("cadence-120", 120, 1), ("cadence-60000-1001", 60000, 1001)]:
        project = create(name, [
            {"videoSettings": {"settings": settings(180, 320, numerator, denominator)}},
            {"addMedia": {"path": str(fixture / f"{name}.mov"), "name": "cadence"}},
        ])
        output = workspace / f"{name}.mp4"
        edit("render", project, "--output", output, "--json")
        verified = run([helper, "verify-cadence", output, "240", numerator, denominator])
        verified["sha256"] = hashlib.sha256(output.read_bytes()).hexdigest()
        cadence_results.append(verified)
        write(workspace / f"{name}-result.json", verified)
    collection = []
    if args.prepare_collection:
        for index, sources in enumerate(manifest["collectionProjects"]):
            operations = [{"videoSettings": {"settings": settings(1080, 1920)}}]
            for shot, source in enumerate(sources):
                operations.append({"addStill": {"path": str(fixture / source["path"]),
                                   "name": source["sourceIdentity"], "duration": (39 if shot < 18 else 38) / 60}})
            project = create(f"collection-{index + 1}", operations)
            shown = edit("show", project, "--json")
            require(len(shown["timeline"]["clips"]) == 45, "Collection project has an incorrect shot count")
            assets = {asset["id"]: asset for asset in shown["assets"]}
            for clip, source in zip(shown["timeline"]["clips"], sources):
                original_still_source(assets[clip["assetId"]]["originalPath"], fixture / source["path"])
            collection.append({"path": project.name, "title": f"Synthetic upload {index + 1}"})
        write(workspace / "publication-projects.json", {"version": 1, "projects": collection})
    require(verify_fixture_contracts(fixture) == contracts, "Visual operations changed fixture sources")
    require(all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in cadence_hashes.items()),
            "Visual operations changed cadence sources")
    report = {"originalStill": detail, "cadences": cadence_results, "collectionProjectsPrepared": len(collection),
              "sourceChecksumsUnchanged": True, "fullDeliveryAcceptance": False}
    write(workspace / "visual-result.json", report)
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
