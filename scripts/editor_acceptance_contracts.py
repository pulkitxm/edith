import argparse
import hashlib
import json
import pathlib


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def checksum(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def original_still_source(imported_path, original_path):
    imported = pathlib.Path(imported_path).resolve(strict=True)
    original = pathlib.Path(original_path).resolve(strict=True)
    require(imported == original, "Imported still must reference the original image, not a proxy or transcoded movie")
    require(imported.suffix.lower() in {".png", ".jpg", ".jpeg", ".tiff", ".heic"}, "Imported source must remain an image")


def unchanged_marker_frames(before, after, expected_frames):
    require(before and set(before) == set(after), "Marker identities changed")
    require(all(type(frame) is int for frame in [*before.values(), *after.values()]), "Marker positions must be exact integer frames")
    require(sorted(before.values()) == sorted(expected_frames), "Initial marker frame positions differ from the fixture")
    require(before == after, "Marker frame positions changed after visual edits or reorder")


def zero_source_reuse(projects, declared_identities):
    require(len(projects) in {5, 6}, "Expected five or six projects")
    identities = {pathlib.Path(path).resolve(strict=True): value for path, value in declared_identities.items()}
    seen_hashes = set()
    seen_identities = set()
    for sources in projects:
        require(len(sources) == 45, "Every collection project must have 45 shots")
        for path in sources:
            path = pathlib.Path(path).resolve(strict=True)
            digest = checksum(path)
            identity = identities.get(path, digest)
            require(digest not in seen_hashes, "Repeated source bytes, including renamed duplicates")
            require(identity not in seen_identities, "Repeated declared source identity, including alternate exports")
            seen_hashes.add(digest)
            seen_identities.add(identity)
    return {"projects": len(projects), "uniqueSources": len(seen_hashes), "zeroSourceReuse": True}


def verify_fixture_contracts(directory):
    directory = directory.resolve(strict=True)
    manifest = json.loads((directory / "extended-manifest.json").read_text())

    def fixture_path(relative):
        path = (directory / relative).resolve(strict=True)
        require(path.is_relative_to(directory), "Fixture path escapes the isolated fixture directory")
        return path

    projects = []
    identities = {}
    for project in manifest["collectionProjects"]:
        paths = []
        for source in project:
            path = fixture_path(source["path"])
            require(checksum(path) == source["sha256"], "Collection fixture source changed")
            paths.append(path)
            identities[path] = source["sourceIdentity"]
        projects.append(paths)
    for alias in manifest["identityAliases"]:
        identities[fixture_path(alias["path"])] = alias["sourceIdentity"]
    original = fixture_path(manifest["originalStill"])
    proxy = fixture_path(manifest["proxyStill"])
    require(checksum(original) == manifest["originalStillSHA256"], "Original still changed")
    require(checksum(proxy) == manifest["proxyStillSHA256"], "Proxy still changed")
    original_still_source(original, original)
    five = zero_source_reuse(projects[:5], identities)
    six = zero_source_reuse(projects, identities)
    markers = {f"beat-{index:02d}": frame for index, frame in enumerate(manifest["markerFrames"])}
    expected = []
    frame = 0
    for index in range(45):
        expected.append(frame)
        frame += 39 if index < 18 else 38
    require(frame == 1728, "Invalid expected marker frame grid")
    unchanged_marker_frames(markers, dict(reversed(list(markers.items()))), expected)

    def rejects(operation, expected_message):
        try:
            operation()
        except AssertionError as error:
            require(str(error).startswith(expected_message), f"Unexpected negative-control failure: {error}")
        else:
            raise AssertionError("Negative control unexpectedly passed")

    rejects(lambda: original_still_source(proxy, original), "Imported still must reference the original image")
    moved = dict(markers)
    moved["beat-02"] += 1
    rejects(lambda: unchanged_marker_frames(markers, moved, expected), "Marker frame positions changed")
    fractional = dict(markers)
    fractional["beat-02"] += 0.25
    rejects(lambda: unchanged_marker_frames(markers, fractional, expected), "Marker positions must be exact integer frames")
    for alias, message in zip(manifest["identityAliases"], ["Repeated source bytes", "Repeated declared source identity"]):
        contaminated = [list(project) for project in projects]
        contaminated[5][0] = fixture_path(alias["path"])
        rejects(lambda: zero_source_reuse(contaminated, identities), message)
    require(checksum(fixture_path(manifest["identityAliases"][1]["path"])) != checksum(projects[0][1]),
            "Alternate-export control must have different bytes")
    return {"fixtureContractsVerified": True, "fiveProjects": five, "sixProjects": six,
            "renamedDuplicateRejected": True, "declaredAlternateExportRejected": True,
            "proxySourceRejected": True, "markerMovementRejected": True, "fractionalMarkerRejected": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Verify synthetic extended acceptance fixtures and negative controls")
    parser.add_argument("--fixture", required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    print(json.dumps(verify_fixture_contracts(arguments.fixture), indent=2, sort_keys=True))
