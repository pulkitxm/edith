import hashlib
import json
import pathlib
import subprocess

from editor_acceptance_publications import exercise_publications, protected_snapshot


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def envelope(value, operation, written=False):
    require(value["version"] == 1 and value["operation"] == operation and value["written"] is written,
            "Media response envelope mismatch")
    return value["result"]


def usage(edit, projects):
    arguments = [argument for project in projects for argument in ("--project", project)]
    before = protected_snapshot(projects)
    offset, occurrences, conflicts, totals = 0, [], [], None
    while True:
        page = envelope(edit("media", "usage", *arguments, "--scope", "visual", "--offset", str(offset), "--limit", "100", "--json"), "usage")
        summary = {key: page[key] for key in ("projectCount", "occurrenceCount", "uniqueClipCount", "uniqueByteIdentityCount",
                   "uniqueOriginalCount", "conflictCount", "assessment", "familyRelationshipStatus", "excludedIndependentAudioCount")}
        require(totals is None or totals == summary, "Media audit totals changed between pages")
        totals = summary
        require(page["offset"] == offset and page["limit"] == 100 and page["scope"] == "visual", "Media audit pagination mismatch")
        occurrences.extend(page["occurrences"])
        conflicts.extend(page["conflicts"])
        next_offset = page.get("nextOffset")
        if next_offset is None:
            break
        require(type(next_offset) is int and offset < next_offset <= 10000, "Invalid media audit next offset")
        offset = next_offset
    require(len(occurrences) == totals["occurrenceCount"] and len(conflicts) == totals["conflictCount"], "Media audit pagination lost rows")
    require([item["index"] for item in occurrences] == list(range(len(occurrences))), "Media occurrence ordering or indices changed")
    require(totals["familyRelationshipStatus"] == "undeclaredReencodesNotRuledOut", "Audit must retain undeclared re-encode uncertainty")
    require(protected_snapshot(projects) == before, "Read-only media audit changed a project")
    return {**totals, "occurrences": occurrences, "conflicts": conflicts}


def unique_usage(report, projects, count):
    require(report["projectCount"] == projects and report["occurrenceCount"] == report["uniqueClipCount"] == count,
            "Visual occurrence or clip count mismatch")
    require(report["uniqueByteIdentityCount"] == report["uniqueOriginalCount"] == count
            and report["conflictCount"] == 0 and report["assessment"] == "noKnownReuse", "Unexpected known source reuse")


def exercise_media(edit, ed, projects, workspace, fixture, audit_project):
    require(len(projects) == 6, "Media collection acceptance requires six synthetic projects")
    fixture = fixture.resolve(strict=True)
    source_snapshot = protected_snapshot([*projects, fixture])
    copies = []
    expected_hashes = {}
    for index, source in enumerate(projects):
        project = workspace / f"indexed-collection-{index + 1}.openscreen"
        edit("clone", source, "--output", project, "--title", f"Synthetic collection {index + 1}", "--json")
        before = project.read_bytes()
        envelope(edit("media", "index", project, "--probe", "--dry-run", "--json"), "index")
        require(project.read_bytes() == before, "Media index dry run changed project bytes")
        envelope(edit("media", "index", project, "--probe", "--overwrite", "--json"), "index", True)
        shown = edit("show", project, "--json")
        for asset in shown["assets"]:
            path = pathlib.Path(asset.get("edithSourceImagePath", asset["originalPath"]))
            expected_hashes[(shown["project"]["id"], asset["id"])] = hashlib.sha256(path.read_bytes()).hexdigest()
        copies.append(project)
    current = usage(edit, [audit_project])
    unique_usage(current, 1, 45)
    require(current["excludedIndependentAudioCount"] > 0, "Visual audit must exclude generated independent music")
    for count in (1, 5, 6):
        report = usage(edit, copies[:count])
        unique_usage(report, count, count * 45)
        for row in report["occurrences"]:
            require(row["sourceRangeComparable"] is False, "Still originals must not claim comparable carrier ranges")
            require(row["source"]["identity"]["sha256"] == expected_hashes[(row["projectID"], row["assetID"])], "Audit did not hash the original still")
    inventory = json.loads((fixture / "extended-manifest.json").read_text())
    aliases = []
    for index, alias in enumerate(inventory["identityAliases"]):
        project = workspace / f"reuse-control-{index}.openscreen"
        plan = workspace / f"reuse-control-{index}.json"
        plan.write_text(json.dumps({"version": 1, "operations": [
            {"addStill": {"path": str(fixture / alias["path"]), "name": "control", "duration": 1}}
        ]}) + "\n")
        edit("create", project, "--title", "Synthetic reuse control", "--json")
        edit("apply", project, "--plan", plan, "--overwrite", "--json")
        aliases.append(project)
    duplicate = usage(edit, [copies[0], aliases[0]])
    require(duplicate["assessment"] == "knownReuseDetected" and duplicate["uniqueOriginalCount"] == 45
            and duplicate["occurrenceCount"] == 46 and duplicate["conflictCount"] == 1, "Renamed duplicate was not detected")
    conflict = duplicate["conflicts"][0]
    require(conflict["exactBytesRepeated"] and conflict["crossProject"] and conflict["wholeOriginalReuse"]
            and conflict["rangeRelationship"] == "notComparableForStillOriginals", "Incorrect renamed-still conflict semantics")
    unique_usage(usage(edit, [copies[0], aliases[1]]), 2, 46)
    original_assets = edit("show", copies[0], "--json")["assets"]
    original_id = next(asset["id"] for asset in original_assets if pathlib.Path(asset["originalPath"]).name == "source-002.png")
    alternate_id = edit("show", aliases[1], "--json")["assets"][0]["id"]
    for project, asset_id in ((copies[0], original_id), (aliases[1], alternate_id)):
        envelope(edit("media", "provenance", project, "--asset", asset_id, "--family", "synthetic-original-002",
                      "--declaration", "Synthetic alternate encoding of source 002", "--overwrite", "--json"), "provenance", True)
    alternate = usage(edit, [copies[0], aliases[1]])
    require(alternate["assessment"] == "knownReuseDetected" and alternate["uniqueByteIdentityCount"] == 46
            and alternate["uniqueOriginalCount"] == 45 and alternate["conflictCount"] == 1, "Declared alternate export was not grouped")
    require(alternate["conflicts"][0]["declaredFamilyRepeated"] and not alternate["conflicts"][0]["exactBytesRepeated"],
            "Declared family conflict was incorrectly classified as duplicate bytes")
    ledger = workspace / "synthetic-ledger.json"
    receipts = workspace / "synthetic-receipts"
    receipts.mkdir()
    for index, project in enumerate(copies):
        result = edit("media", "reserve", project, "--ledger", ledger, "--reel", f"synthetic-reel-{index + 1}", "--json")
        reservation = envelope(result, "reserve", True)["receipt"]
        require(reservation["reelID"] == f"synthetic-reel-{index + 1}" and len(reservation["keys"]) >= 45, "Incomplete source reservation")
        (receipts / f"receipt-{index + 1}.json").write_text(json.dumps(result, indent=2) + "\n")
    protected = protected_snapshot([*copies, ledger, receipts])
    for project in aliases:
        failed = subprocess.run([str(ed), "studio", "edit", "media", "reserve", str(project), "--ledger", str(ledger),
                                 "--reel", "synthetic-conflict", "--json"], capture_output=True, text=True, timeout=1800)
        require(failed.returncode != 0 and not failed.stdout and json.loads(failed.stderr)["error"]["code"] == "source_reserved",
                "Ledger did not reject the isolated source-reuse control")
    listed, offset = [], 0
    while True:
        page = envelope(edit("media", "reservations", "--ledger", ledger, "--offset", str(offset), "--limit", "2", "--json"), "reservations")
        require(page["total"] == 6, "Reservation count changed")
        listed.extend(page["receipts"])
        if page.get("nextOffset") is None:
            break
        require(page["nextOffset"] > offset, "Reservation pagination did not advance")
        offset = page["nextOffset"]
    require({receipt["reelID"] for receipt in listed} == {f"synthetic-reel-{index + 1}" for index in range(6)}, "Reservation pagination lost owners")
    publication = exercise_publications(edit, copies, workspace, [ledger, receipts])
    require(protected_snapshot([*copies, ledger, receipts]) == protected, "Publication or rejected reservations changed protected state")
    package = workspace / "synthetic-package"
    packaged = envelope(edit("media", "package", copies[0], "--output", package, "--json"), "package", True)
    require(packaged["copiedFileCount"] == 45, "Package did not copy every still original exactly once")
    for entry in packaged["manifest"]["entries"]:
        copied = (package / entry["packagedPath"]).resolve(strict=True)
        require(copied.is_relative_to(package.resolve()) and hashlib.sha256(copied.read_bytes()).hexdigest() == entry["source"]["identity"]["sha256"],
                "Package original identity mismatch")
    moved = workspace / "moved-synthetic-package"
    package.rename(moved)
    packaged_project = moved / "project.openscreen"
    before = packaged_project.read_bytes()
    envelope(edit("media", "open", moved, "--dry-run", "--json"), "open")
    require(packaged_project.read_bytes() == before, "Package open dry run changed project bytes")
    envelope(edit("media", "open", moved, "--overwrite", "--json"), "open", True)
    unique_usage(usage(edit, [packaged_project]), 1, 45)
    for receipt in sorted(receipts.glob("*.json")):
        released = envelope(edit("media", "release", "--ledger", ledger, "--receipt", receipt, "--json"), "release", True)
        require(released["released"] is True, "Reservation was not released")
    require(envelope(edit("media", "reservations", "--ledger", ledger, "--json"), "reservations")["total"] == 0, "Ledger was not empty after release")
    require(protected_snapshot([*copies, receipts]) == {key: value for key, value in protected.items() if key != str(ledger.resolve())},
            "Package or release changed project provenance or reservation receipts")
    require(protected_snapshot([*projects, fixture]) == source_snapshot, "Media acceptance modified its original projects or fixtures")
    return {"visualCounts": [45, 225, 270], "knownReuseDetectedForRenamedBytes": True, "declaredAlternateExportDetected": True,
            "familyRelationshipStatus": "undeclaredReencodesNotRuledOut", "stillOriginalHashesVerified": True,
            "reservationConflictsVerified": True, "reservationsReleased": 6, "packageRelocationVerified": True, "publication": publication}
