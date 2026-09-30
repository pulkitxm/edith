import json
import os
import pathlib
import subprocess
import tempfile

from editor_acceptance_contracts import require
from editor_acceptance_delivery import checked_progress
from editor_parity_fixtures import FRAME_RATE, checksum, write_json


REQUIRED_GROUPS = {"cliTransactions", "editableProject", "captions", "independentPixels", "immediateReview",
                   "masteredAudio", "aacPacketPassthrough", "nativeLifecycle", "delivery", "protectedSources", "sourceTimingAndMotion"}


def invoke(ed, *arguments, stdin=None, failure=False, environment=None):
    process = subprocess.run([str(ed), "studio", "edit", *(str(value) for value in arguments)], input=stdin,
                             capture_output=True, text=True, timeout=7200, env=environment)
    if failure:
        require(process.returncode != 0 and not process.stdout, "Rejected edit unexpectedly succeeded or emitted a success result")
        return json.loads(process.stderr)["error"]
    require(process.returncode == 0, f"Public edit command failed ({process.returncode}): {process.stderr}")
    if "--progress" in arguments:
        checked_progress(process.stderr)
    return json.loads(process.stdout)


def discover(ed, workspace, operations, environment=None):
    schema = invoke(ed, "schema", "--json", environment=environment)
    variants = schema["properties"]["operations"]["items"]["oneOf"]
    available = {next(iter(variant["properties"])): variant for variant in variants}
    require(set(operations) <= available.keys(), f"Integrated CLI is missing required public operations: {sorted(set(operations) - available.keys())}")
    selected = {}
    for name in sorted(operations):
        selected[name] = invoke(ed, "schema", "--operation", name, "--json", environment=environment)
        require(selected[name]["properties"] == available[name]["properties"], "Targeted operation schema differs from capability discovery")
    write_json(workspace / "discovered-schema.json", {"document": schema, "operations": selected})
    return selected


def base_operations(manifest, dimensions):
    operations = [
        {"videoSettings": {"settings": {"width": dimensions[0], "height": dimensions[1],
                                       "frameRateNumerator": FRAME_RATE, "frameRateDenominator": 1, "colorSpace": "rec709"}}},
        {"canvas": {"aspectRatio": "9:16", "padding": 0, "backgroundColor": "#000000"}},
    ]
    for shot in manifest["shots"]:
        if shot["kind"] == "photo":
            operations.append({"addStill": {"path": shot["path"], "name": shot["name"], "duration": shot["frames"] / FRAME_RATE}})
        else:
            operations.extend([
                {"addMedia": {"path": shot["path"], "name": shot["name"]}},
                {"trim": {"clipID": shot["name"], "start": shot["sourceStartFrame"] / FRAME_RATE,
                          "end": (shot["sourceStartFrame"] + shot["frames"]) / FRAME_RATE}},
                {"sourceAudio": {"clipID": shot["name"], "gainDb": 0, "muted": True}},
            ])
    operations.append({"addAudio": {"path": manifest["music"]["path"], "start": 0, "offset": 0, "name": "synthetic-score"}})
    return operations


def exercise_transactions(ed, project, plan, fixture, workspace, environment=None):
    def edit(*arguments, **options):
        return invoke(ed, *arguments, environment=environment, **options)

    plan_path = workspace / "public-plan.json"
    write_json(plan_path, plan)
    edit("create", project, "--title", "Synthetic editor parity", "--json")
    original = checksum(project)
    summary = edit("show", project, "--summary", "--json")
    require(summary["revision"] == original, "Compact summary revision differs from exact project bytes")
    common = ["--media-directory", fixture, "--expect-revision", original, "--json"]
    preview = edit("apply", project, "--plan", plan_path, "--dry-run", *common)
    require(preview["written"] is False and checksum(project) == original, "Plan dry run changed the original project")
    result = edit("apply", project, "--plan", "-", "--overwrite", *common, stdin=json.dumps(plan))
    require(result["written"] is True and len(result["aliases"]) == 47, "Stdin plan did not persist all 47 original aliases")
    revision = checksum(project)
    require(result["sourceRevision"] == original and result["revision"] == revision, "Apply revision report does not match saved bytes")
    stale = edit("apply", project, "--plan", "-", "--overwrite", *common, stdin=json.dumps({"version": 1, "operations": []}), failure=True)
    require(stale["code"] == "project_changed" and checksum(project) == revision, "Stale revision was not rejected without changing the project")
    failing = {"version": 1, "operations": [{"rename": {"title": "Must roll back"}}, {"remove": {"clipID": "synthetic-missing-clip"}}]}
    error = edit("apply", project, "--plan", "-", "--overwrite", "--json", stdin=json.dumps(failing), failure=True)
    require(error["code"] == "invalid_operation" and error["operationIndex"] == 1 and error["cause"],
            "Failed transaction did not identify its exact operation and cause")
    require(checksum(project) == revision, "Failed transaction partially persisted its successful first operation")
    edit("validate", project, "--json")
    return {"planDryRunPreservedBytes": True, "stdinAndRelativeMedia": True, "revisionGuard": True,
            "failedOperationRolledBack": True, "structuredOperationError": True}


def publish_result(workspace, groups, mode):
    require(mode in {"quick", "full"}, "Unknown acceptance mode")
    require(set(groups) == REQUIRED_GROUPS and all(isinstance(value, dict) and value for value in groups.values()),
            "Every required acceptance group must complete before publishing a result")
    result = {"version": 1, "syntheticAcceptance": True, "realProjectParityVerified": False,
              "fullDeliveryAcceptance": mode == "full", "mode": mode, "groups": groups}
    destination = workspace / ("result.json" if mode == "full" else "quick-result.json")
    descriptor, name = tempfile.mkstemp(prefix=".result-", suffix=".tmp", dir=workspace)
    temporary = pathlib.Path(name)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(json.dumps(result, indent=2, sort_keys=True) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, destination, follow_symlinks=False)
        except FileExistsError as error:
            raise AssertionError("Acceptance result destination must not already exist") from error
    finally:
        temporary.unlink(missing_ok=True)
    return result
