import json
import pathlib
from fractions import Fraction

from editor_acceptance_captions import exercise_caption_preservation


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def marker_snapshot(report):
    require(report["version"] == 1 and report["positionUnit"] == "output_frames", "Unexpected marker report units")
    result = {}
    for marker in report["markers"]:
        frame = marker["frame"]
        rate = marker["frameRate"]
        require(type(frame) is int and frame >= 0, "Marker positions must be exact nonnegative frames")
        require(marker["id"] not in result, "Duplicate marker identity")
        time = Fraction(frame * rate["denominator"], rate["numerator"])
        require(abs(float(time) - marker["outputSeconds"]) < 1e-12, "Marker seconds disagree with its rational position")
        result[marker["id"]] = (frame, rate["numerator"], rate["denominator"], marker["label"], marker["kind"])
    return result


def mapped_frames(samples, sample_rate, source_in, source_out, output_start, playback_rate, fps):
    frames = set()
    for sample in samples:
        time = Fraction(sample, sample_rate)
        if source_in <= time < source_out:
            position = (output_start + (time - source_in) / playback_rate) * fps
            frames.add((2 * position.numerator + position.denominator) // (2 * position.denominator))
    return sorted(frames)


def check_analysis(report, expected_source):
    require(report["samplePositionUnit"] == "source_samples" and report["sampleRateUnit"] == "Hz", "Audio analysis unit mismatch")
    require(pathlib.Path(report["sourcePath"]).resolve(strict=True) == expected_source.resolve(strict=True), "Analysis selected the wrong audio source")
    analysis = report["analysis"]
    require(analysis["sampleRate"] == 48000 and analysis["sampleCount"] == 1382400, "Audio analysis sample count or rate changed")
    require(abs(report["durationSeconds"] - 28.8) < 1e-12, "Audio analysis duration mismatch")
    require(0 < len(analysis["waveform"]) <= 64, "Waveform exceeded the requested bound")
    position = 0
    energy = 0
    for bin in analysis["waveform"]:
        require(bin["startSample"] == position and bin["sampleCount"] > 0, "Waveform bins have a gap or overlap")
        require(0.19 <= bin["peak"] <= 0.21, "Waveform peak does not match the generated tone")
        energy += bin["meanSquare"] * bin["sampleCount"]
        position += bin["sampleCount"]
    require(position == 1382400 and abs(energy / position - 0.02) < 0.0001, "Waveform energy or coverage changed")
    transients = analysis["transients"]
    require(0 < len(transients) <= 8 and not analysis["transientsTruncated"], "Unexpected tone transient count or truncation")
    expected = mapped_frames([item["sample"] for item in transients], 48000,
                             Fraction(0), Fraction(2), Fraction(3), Fraction(2), Fraction(60000, 1001))
    document = report["markerDocument"]
    require(document["version"] == 1 and [item["frame"] for item in document["markers"]] == expected,
            "Source-sample to output-frame mapping changed")
    require(all(item["frameRate"] == {"numerator": 60000, "denominator": 1001}
                and item["kind"] == "transient" for item in document["markers"]), "Mapped marker rate or kind changed")
    return {"waveformBins": len(analysis["waveform"]), "transients": len(transients),
            "sampleUnitsVerified": True, "rationalMappingVerified": True}


def exercise_markers(edit, source, workspace, manifest, captions=True):
    project = workspace / "marker-acceptance.openscreen"
    plan = workspace / "marker-copy-plan.json"
    plan.write_text(json.dumps({"version": 1, "operations": []}) + "\n")
    edit("apply", source, "--plan", plan, "--output", project, "--json")
    shown = edit("show", project, "--json")
    music = [asset for asset in shown["assets"] if pathlib.Path(asset["originalPath"]).name == "music.wav"]
    require(len(music) == 1, "Expected exactly one generated music asset for analysis")
    expected_source = pathlib.Path(music[0].get("edithAudioPath", music[0]["originalPath"]))
    before_analysis = project.read_bytes()
    analysis = edit("audio", "analyze", project, "--asset", music[0]["id"], "--maximum-waveform-bins", "64",
                    "--maximum-transients", "8", "--source-in", "0", "--source-out", "2", "--output-start", "3",
                    "--playback-rate", "2", "--fps", "60000/1001", "--json")
    analysis_result = check_analysis(analysis, expected_source)
    require(project.read_bytes() == before_analysis, "Audio analysis changed project bytes")
    markers = []
    position = 0
    for index, shot in enumerate(manifest["shots"]):
        markers.append({"id": f"acceptance-beat-{index:02d}", "frame": position,
                        "frameRate": {"numerator": 60, "denominator": 1}, "label": f"Synthetic beat {index + 1}", "kind": "manual"})
        position += shot["frames"]
    require(position == 1728 and len(markers) == 45, "Invalid shot-aligned marker fixture")
    marker_document = {"version": 1, "markers": markers}
    marker_file = workspace / "beat-markers.json"
    marker_file.write_text(json.dumps(marker_document, indent=2) + "\n")
    preview = edit("markers", "import", project, "--input", marker_file, "--dry-run", "--json")
    require(preview["written"] is False and project.read_bytes() == before_analysis, "Marker import dry run changed project bytes")
    imported = edit("markers", "import", project, "--input", marker_file, "--json")
    before = marker_snapshot(imported)
    require({item[0] for item in before.values()} == {item["frame"] for item in markers}, "Marker import changed beat frames")
    added = edit("markers", "add", project, "--frame", "60", "--fps", "60000/1001", "--label", "Synthetic rational marker", "--json")
    new_ids = set(marker_snapshot(added)) - set(before)
    require(len(new_ids) == 1, "Marker add must create one stable ID")
    extra = new_ids.pop()
    require(marker_snapshot(added)[extra][:3] == (60, 60000, 1001), "Marker add rounded rational FPS")
    updated = edit("markers", "update", project, "--id", extra, "--fps", "120", "--json")
    require(marker_snapshot(updated)[extra][:3] == (120, 120, 1), "FPS-only marker update did not preserve nearest output time")
    edit("markers", "remove", project, "--id", extra, "--json")
    require(marker_snapshot(edit("markers", "list", project, "--json")) == before, "Marker CRUD changed existing beats")
    snapped = edit("markers", "snap", project, "--frame", "721", "--fps", "60", "--threshold-frames", "19", "--json")
    require(snapped["matched"] is True and snapped["outputFrame"] == 702, "Marker snap tie must choose the earlier frame")
    exported = workspace / "beat-markers-export.json"
    edit("markers", "export", project, "--output", exported, "--json")
    require(json.loads(exported.read_text()) == marker_document, "Marker interchange round trip changed content")
    edit("markers", "import", project, "--input", exported, "--replace", "--json")
    exported_again = workspace / "beat-markers-roundtrip.json"
    edit("markers", "export", project, "--output", exported_again, "--json")
    require(exported.read_bytes() == exported_again.read_bytes(), "Marker export is not deterministic")
    ids = {item["frame"]: item["id"] for item in markers}

    def verify_then_move_markers(caption_project):
        require(marker_snapshot(edit("markers", "list", caption_project, "--json")) == before,
                "Visual edits, FPS changes, speed, or reorder moved beat markers")
        edit("markers", "update", caption_project, "--id", ids[39], "--frame", "40", "--fps", "60", "--json")
        edit("markers", "remove", caption_project, "--id", ids[0], "--json")

    if not captions:
        return {"markers": 45, "rationalCRUDVerified": True, "snapTieVerified": True,
                "interchangeRoundTripVerified": True, "analysis": analysis_result, "captions": {"pending": True}}
    captions = exercise_caption_preservation(edit, project, workspace, ids, verify_then_move_markers)
    return {"markers": 45, "exactBeatFramesPreserved": True, "rationalCRUDVerified": True,
            "snapTieVerified": True, "interchangeRoundTripVerified": True, "analysis": analysis_result,
            "captionSnapshotsSurvivedMarkerMoveAndRemoval": True, "captions": captions}
