import argparse
import copy
import json
import os
import pathlib
import uuid
from fractions import Fraction

from editor_acceptance_contracts import require
from editor_acceptance_captions import caption_snapshot
from editor_parity_adapters import caption_operations
from editor_parity_cli import discover, invoke
from editor_parity_fixtures import checksum, ffmpeg, write_json
from editor_parity_identity import runtime_identity, verify_runtime
from editor_parity_style_probe import styled_pixel_probe


def main():
    parser = argparse.ArgumentParser(description="Actual public caption creation and returned-ID update semantics")
    parser.add_argument("--ed", type=pathlib.Path, required=True)
    parser.add_argument("--workspace", type=pathlib.Path, required=True)
    parser.add_argument("--styled-probe", action="store_true")
    args = parser.parse_args()
    workspace = args.workspace.absolute()
    require(not workspace.exists(), "Caption creation workspace must be new")
    identity = runtime_identity(args.ed)
    ed = pathlib.Path(identity["entrypointPath"])
    workspace.mkdir(parents=True)
    runtime = {"EDITH_DATA_ROOT": str(workspace / "runtime"), "EDITH_SHARED_DEFAULTS_SUITE": f"com.pulkit.edith.caption-create.{uuid.uuid4().hex}"}
    environment = {**os.environ, **runtime}
    write_json(workspace / "runtime-environment.json", runtime)
    def edit(*arguments, **options):
        return invoke(ed, *arguments, environment=environment, **options)
    schemas = discover(ed, workspace, {"outputCaption"}, environment)
    source, project = workspace / "synthetic-blue.png", workspace / "captions.openscreen"
    ffmpeg("-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", "36x64", "-i", "pipe:0",
           "-frames:v", "1", "-update", "1", source, data=bytes((120, 160, 200)) * (36 * 64))
    source_digest = checksum(source)
    shots = [{"name": f"shot-{index}", "caption": text, "fontSize": size, "startFrame": index * 2, "endFrame": index * 2 + 2}
             for index, (text, size) in enumerate([("Amber Harbor", 104), ("Amber Harbor\nCobalt Meadow", 104), ("Amber Harbor", 112)])]
    operations, styles = caption_operations({"shots": shots}, schemas)
    require(all("id" not in operation["outputCaption"] for operation in operations), "Creation plan must let the public CLI allocate identities")
    edit("create", project, "--title", "Synthetic caption creation semantics", "--json")
    base = [{"videoSettings": {"settings": {"width": 2160, "height": 3840, "frameRateNumerator": 60, "frameRateDenominator": 1, "colorSpace": "rec709"}}},
            {"addStill": {"path": str(source), "name": "synthetic-blue", "duration": 6 / 60}}]
    edit("apply", project, "--plan", "-", "--overwrite", "--json", stdin=json.dumps({"version": 1, "operations": base + operations}))
    report = edit("captions", "list", project, "--json")
    snapshot = caption_snapshot(report)
    ordered = sorted(report["captions"], key=lambda value: value["startSeconds"])
    require(len(snapshot) == 3, "Public caption creation did not assign three unique identities")
    for caption, shot in zip(ordered, shots):
        prefix, value = caption["id"].split("_", 1)
        require(prefix == "annotation", "Unexpected public caption identity namespace")
        uuid.UUID(value)
        require(snapshot[caption["id"]][:2] == (Fraction(shot["startFrame"], 60), Fraction(shot["endFrame"], 60))
                and caption["content"] == shot["caption"] and caption["style"] == styles[shot["name"]],
                "Public caption creation changed text, exact anchors, or style")
    identifier = ordered[0]["id"]
    update = copy.deepcopy(operations[0])
    update["outputCaption"].update(id=identifier, content="Synthetic returned-ID update")
    edit("apply", project, "--plan", "-", "--overwrite", "--json", stdin=json.dumps({"version": 1, "operations": [update]}))
    updated = edit("captions", "list", project, "--json")
    require(caption_snapshot(updated) == snapshot, "Returned-ID update changed identities or rational anchors")
    for caption in updated["captions"]:
        original = next(value for value in ordered if value["id"] == caption["id"])
        expected = {**original, "content": "Synthetic returned-ID update"} if caption["id"] == identifier else original
        require(caption == expected, "Returned-ID update affected unexpected caption fields")
    before = checksum(project)
    unknown = copy.deepcopy(update)
    unknown["outputCaption"]["id"] = "synthetic-nonexistent-caption"
    error = edit("apply", project, "--plan", "-", "--overwrite", "--json",
                 stdin=json.dumps({"version": 1, "operations": [{"rename": {"title": "Must roll back"}}, unknown]}), failure=True)
    require(error["code"] == "invalid_operation" and error["cause"] == "not_found" and error["operationIndex"] == 1,
            "Unknown supplied caption ID did not produce the public update error")
    require(checksum(project) == before and edit("captions", "list", project, "--json") == updated,
            "Rejected caption update changed project bytes or caption state")
    require(checksum(source) == source_digest, "Caption semantics test modified its synthetic original")
    verify_runtime(identity, "after native caption semantics")
    result = {"productAcceptance": False, "createdCaptions": 3, "publicAssignedUniqueUUIDs": True,
              "exactAnchorsAndStyles": True, "returnedIDUpdatePreservedOtherCaptions": True,
              "unknownIDRejectedWithRollback": True, "syntheticSourcePreserved": True, "runtimeIdentity": identity}
    write_json(workspace / "caption-creation-checks.json", result)
    if args.styled_probe:
        try:
            styled = styled_pixel_probe(edit, workspace, schemas)
        except Exception as error:
            write_json(workspace / "styled-probe-checks.json", {"productAcceptance": False, "passed": False, "error": str(error)})
            raise
        verify_runtime(identity, "after actual native styled probe")
        write_json(workspace / "styled-probe-checks.json", {"productAcceptance": False, "passed": True, "runtimeIdentity": identity, "checks": styled})
        result["styledProbePassed"] = True
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
