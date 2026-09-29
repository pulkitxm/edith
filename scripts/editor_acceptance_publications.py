import hashlib
import json
import os
import pathlib


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def protected_snapshot(paths):
    result = {}
    for item in paths:
        path = pathlib.Path(item).resolve(strict=True)
        files = sorted(path.rglob("*")) if path.is_dir() else [path]
        for file in files:
            if file.is_file():
                result[str(file)] = (hashlib.sha256(file.read_bytes()).hexdigest(), file.stat().st_mtime_ns)
    return result


def publication_reordered(before, after, order):
    require(before["version"] == after["version"] == 1, "Unexpected publication version")
    items = {item["projectID"]: item for item in before["items"]}
    require(len(items) == len(before["items"]), "Publication IDs must be unique")
    require(len(order) == len(items) and set(order) == set(items), "Publication order must contain every project exactly once")
    require(after["items"] == [items[identifier] for identifier in order], "Publication reorder changed project identity, path, or title")


def exercise_publications(edit, projects, workspace, protected_files=()):
    projects = [pathlib.Path(path).resolve(strict=True) for path in projects]
    protected_files = list(protected_files)
    require(len(projects) in {5, 6}, "Publication acceptance needs five or six synthetic projects")
    require(len(set(projects)) == len(projects), "Publication projects must be distinct files")
    before = protected_snapshot([*projects, *protected_files])
    identities = []
    for project in projects:
        shown = edit("show", project, "--json")
        require(len(shown["timeline"]["clips"]) == 45, "Every publication project must have 45 shots")
        identities.append(shown["project"]["id"])
    require(len(set(identities)) == len(projects), "Publication projects must have distinct native IDs")
    inputs = workspace / "publication-inputs"
    outputs = workspace / "publication-outputs"
    inputs.mkdir()
    outputs.mkdir()
    manifest_path = outputs / "uploads.json"
    counts = [5, 6] if len(projects) == 6 else [5]
    for count in counts:
        project_plan = inputs / f"projects-{count}.json"
        project_plan.write_text(json.dumps({"version": 1, "projects": [
            {"path": os.path.relpath(path, inputs), "title": f"Synthetic upload {index + 1}"}
            for index, path in enumerate(projects[:count])
        ]}, indent=2) + "\n")
        overwrite = ["--overwrite"] if count == 6 else []
        manifest_before = manifest_path.read_bytes() if manifest_path.exists() else None
        preview = edit("publications", "create", manifest_path, "--input", project_plan, *overwrite, "--dry-run", "--json")
        require(preview["written"] is False, "Publication create dry run reported a write")
        require((manifest_path.read_bytes() if manifest_path.exists() else None) == manifest_before,
                "Publication create dry run changed the manifest")
        created = edit("publications", "create", manifest_path, "--input", project_plan, *overwrite, "--json")
        require(created["written"] is True, "Publication creation did not write its manifest")
        manifest = edit("publications", "show", manifest_path, "--json")
        require(manifest == created["manifest"] == preview["manifest"], "Publication create/show disagree")
        require([item["projectID"] for item in manifest["items"]] == identities[:count], "Publication create changed project IDs or order")
        for index, item in enumerate(manifest["items"]):
            require(pathlib.Path(item["projectPath"]).resolve(strict=True) == projects[index], "Input-relative publication path resolved incorrectly")
            require(item["title"] == f"Synthetic upload {index + 1}", "Publication title was not preserved")
        order = [identities[1], identities[0], *identities[2:count]]
        order_plan = inputs / f"order-{count}.json"
        order_plan.write_text(json.dumps({"version": 1, "projectIDs": order}) + "\n")
        manifest_before = manifest_path.read_bytes()
        preview = edit("publications", "reorder", manifest_path, "--input", order_plan, "--overwrite", "--dry-run", "--json")
        publication_reordered(manifest, preview["manifest"], order)
        require(preview["written"] is False and manifest_path.read_bytes() == manifest_before,
                "Publication reorder dry run changed the manifest")
        reordered = edit("publications", "reorder", manifest_path, "--input", order_plan, "--overwrite", "--json")
        publication_reordered(manifest, reordered["manifest"], order)
        require(reordered["written"] is True, "Publication reorder did not write its manifest")
        require(edit("publications", "show", manifest_path, "--json") == reordered["manifest"], "Publication reorder was not persisted")
        require(protected_snapshot([*projects, *protected_files]) == before,
                "Publication order changed project bytes, timestamps, provenance, ledger, or receipts")
        relative = outputs / f"relative-{count}.json"
        relative.write_text(json.dumps({"version": 1, "items": [
            {**item, "projectPath": os.path.relpath(pathlib.Path(item["projectPath"]), outputs)}
            for item in reordered["manifest"]["items"]
        ]}, indent=2) + "\n")
        shown = edit("publications", "show", relative, "--json")
        require([item["projectID"] for item in shown["items"]] == order, "Manifest-relative publication identities changed")
        for item in shown["items"]:
            resolved = (outputs / item["projectPath"]).resolve(strict=True)
            require(resolved == projects[identities.index(item["projectID"])], "Manifest-relative project path resolved incorrectly")
    require(protected_snapshot([*projects, *protected_files]) == before, "Publication show changed protected files")
    return {"projectCounts": counts, "firstProjectMovedToSecond": True, "projectBytesAndTimestampsPreserved": True,
            "relativeInputAndManifestPathsVerified": True, "createAndReorderDryRunsPreservedBytes": True,
            "ledgerAndReceiptPathsChecked": len(protected_files)}
