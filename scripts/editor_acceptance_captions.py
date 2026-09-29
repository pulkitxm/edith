import hashlib
import json
from fractions import Fraction


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def caption_snapshot(report):
    require(report["version"] == 1, "Unexpected caption report version")
    result = {}
    for caption in report["captions"]:
        require(caption["id"] not in result, "Caption IDs must be unique")
        require(caption["clock"] == "output", "Acceptance captions must use the output clock")
        anchor = caption["anchor"]
        times = []
        for boundary in ("start", "end"):
            position = anchor[boundary]
            rate = position["frameRate"]
            frame, numerator, denominator = position["frame"], rate["numerator"], rate["denominator"]
            require(all(type(value) is int for value in (frame, numerator, denominator)), "Caption positions must remain exact integers")
            require(frame >= 0 and numerator > 0 and denominator > 0, "Invalid caption frame position")
            time = Fraction(frame * denominator, numerator)
            require(abs(float(time) - caption[boundary + "Seconds"]) < 1e-12, "Caption seconds disagree with its rational anchor")
            times.append(time)
        require(times[0] < times[1], "Caption interval must be nonempty and half-open")
        result[caption["id"]] = (*times, json.dumps(anchor, sort_keys=True))
    return result


def unchanged_captions(before, after):
    require(before == caption_snapshot(after), "Caption identities, rational times, or marker provenance changed")


def seed_beat_captions(edit, project, marker_ids=None):
    marker_ids = marker_ids or {}
    starts = [0]
    for index in range(44):
        starts.append(starts[-1] + (39 if index < 18 else 38))
    if marker_ids:
        require({starts[index] for index in (0, 1, 18, 19, 44)} <= set(marker_ids), "Missing beat marker IDs for caption boundaries")
    expected = {}
    created = []
    for index in (0, 18, 44):
        start = starts[index]
        end = starts[index + 1] if index < 44 else 1728
        arguments = ["captions", "add", project, "--text", f"Synthetic beat {index + 1}", "--fps", "60", "--json"]
        arguments += ["--start-marker", marker_ids[start]] if start in marker_ids else ["--start-frame", str(start)]
        arguments += ["--end-marker", marker_ids[end]] if end in marker_ids else ["--end-frame", str(end)]
        added = edit(*arguments)
        identifier = added["captionID"]
        require(added["written"] is True, "Caption add was not persisted")
        require(caption_snapshot(added)[identifier][:2] == (Fraction(start, 60), Fraction(end, 60)), "Beat caption timing differs from the fixture")
        if end in marker_ids:
            updated = edit("captions", "update", project, identifier, "--end-marker", marker_ids[end], "--json")
            require(updated["captionID"] == identifier, "Caption update changed its ID")
            position = next(item for item in updated["captions"] if item["id"] == identifier)["anchor"]["end"]
            require(position["markerID"] == marker_ids[end], "Caption lost marker provenance")
        expected[identifier] = (Fraction(start, 60), Fraction(end, 60))
        created.append(identifier)
    rational = edit("captions", "add", project, "--text", "Synthetic rational caption",
                    "--start-frame", "12", "--end-frame", "24", "--fps", "60000/1001", "--json")
    expected[rational["captionID"]] = (Fraction(12012, 60000), Fraction(24024, 60000))
    before = caption_snapshot(edit("captions", "list", project, "--json"))
    require(set(before) == set(expected), "Unexpected acceptance captions")
    require(all(before[identifier][:2] == times for identifier, times in expected.items()), "Caption timing was rounded")
    text_only = edit("captions", "update", project, created[0], "--text", "Synthetic first beat revised", "--json")
    unchanged_captions(before, text_only)
    return before


def exercise_caption_preservation(edit, source, workspace, marker_ids=None, additional_mutations=None):
    project = workspace / "caption-acceptance.openscreen"
    plan = workspace / "caption-copy-plan.json"
    plan.write_text(json.dumps({"version": 1, "operations": []}) + "\n")
    edit("apply", source, "--plan", plan, "--output", project, "--json")
    before = seed_beat_captions(edit, project, marker_ids)
    shown = edit("show", project, "--json")
    clips = shown["timeline"]["clips"]
    settings = {**shown["edithVideoSettings"], "frameRateNumerator": 60000, "frameRateDenominator": 1001}
    plan.write_text(json.dumps({"version": 1, "operations": [
        {"crop": {"clipID": clips[0]["id"], "x": 0.1, "y": 0.1, "width": 0.8, "height": 0.8}},
        {"speed": {"clipID": clips[0]["id"], "rate": 2}},
        {"reorder": {"clipIDs": [clip["id"] for clip in reversed(clips)]}},
        {"videoSettings": {"settings": settings}},
        {"visualEffects": {"clipID": clips[0]["id"], "effects": {
            "framing": "fill", "focalX": 0.5, "focalY": 0.5, "exposure": 0,
            "brightness": 0, "contrast": 1.1, "saturation": 1, "keyframes": [
                {"time": 0, "scale": 1, "positionX": 0, "positionY": 0, "rotation": 0, "interpolation": "smooth"},
                {"time": 0.5, "scale": 1.1, "positionX": 0.02, "positionY": 0, "rotation": 2, "interpolation": "linear"},
            ],
        }}},
    ]}, indent=2) + "\n")
    edit("apply", project, "--plan", plan, "--overwrite", "--json")
    unchanged_captions(before, edit("captions", "list", project, "--json"))
    if additional_mutations:
        additional_mutations(project)
        unchanged_captions(before, edit("captions", "list", project, "--json"))
    identifier = next(iter(before))
    checksum = hashlib.sha256(project.read_bytes()).hexdigest()
    removal = edit("captions", "remove", project, identifier, "--dry-run", "--json")
    require(removal["written"] is False and hashlib.sha256(project.read_bytes()).hexdigest() == checksum,
            "Caption removal dry run changed project bytes")
    unchanged_captions(before, edit("captions", "list", project, "--json"))
    removed = edit("captions", "remove", project, identifier, "--json")
    unchanged_captions({key: value for key, value in before.items() if key != identifier}, removed)
    return {"captions": len(before), "rationalAnchorsPreserved": True, "textUpdatePreservedTiming": True,
            "cropSpeedReorderPreservedTiming": True, "markerBindingsExercised": bool(marker_ids),
            "projectFPSAndVisualEffectsPreservedTiming": True,
            "additionalMutationsExercised": additional_mutations is not None, "removeDryRunPreservedBytes": True}
