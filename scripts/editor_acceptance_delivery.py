import hashlib
import json
import subprocess
from fractions import Fraction


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def checked_progress(stderr):
    events = [json.loads(line) for line in stderr.splitlines() if line.strip()]
    require(1 <= len(events) <= 101, "Delivery progress must have 1 through 101 events")
    require(all(set(event) == {"version", "event", "percent"} and event["version"] == 1
                and event["event"] == "progress" and type(event["percent"]) is int
                and 0 <= event["percent"] <= 100 for event in events), "Invalid delivery progress event")
    percentages = [event["percent"] for event in events]
    require(percentages[-1] == 100 and all(left < right for left, right in zip(percentages, percentages[1:])),
            "Delivery progress must increase strictly and finish at 100")
    return len(events)


def checked_report(result, path, kind, frames, start=None, end=None):
    require(result["version"] == 1 and result["written"] is True, "Delivery was not published")
    report = result[kind + "Report"]
    require(report["sha256"] == hashlib.sha256(path.read_bytes()).hexdigest(), "Delivery report checksum mismatch")
    require(report["bytes"] == path.stat().st_size, "Delivery report byte count mismatch")
    if kind == "video":
        require(report["width"] == 1080 and report["height"] == 1920, "Delivery report dimensions mismatch")
        require(report["frameCount"] == frames, "Delivery report frame count mismatch")
        require(report["audioSampleRate"] == 48000 and report["audioChannels"] == 2, "Video music report format mismatch")
        require(Fraction(report["frameRateNumerator"], report["frameRateDenominator"]) == 60, "Delivery report cadence mismatch")
        duration = frames / 60
    else:
        require(report["sampleRate"] == 48000 and report["channels"] == 2, "Audio delivery report format mismatch")
        require(report["frames"] == frames and report["codec"] == "lpcm" and report["bitsPerSample"] == 24,
                "Audio delivery report must measure exact 24-bit PCM samples")
        duration = frames / 48000
    require(abs(report["duration"] - duration) < 1e-12, "Delivery report duration mismatch")
    if start is not None:
        selection = report["range"]
        require(selection["startFrame"] == start and selection["endFrame"] == end
                and Fraction(selection["frameRateNumerator"], selection["frameRateDenominator"]) == 60,
                "Delivery range report mismatch")
    else:
        require("range" not in report, "Unexpected range in full delivery report")
    return report


def execute(arguments):
    process = subprocess.run([str(value) for value in arguments], capture_output=True, text=True, timeout=1800)
    require(process.returncode == 0, f"Delivery failed ({process.returncode}): {process.stderr}")
    if "--progress" in arguments:
        checked_progress(process.stderr)
    return json.loads(process.stdout)


def exercise_delivery(ed, project, workspace, helper):
    project_bytes = project.read_bytes()
    results = {}
    for name, start, end in [("full-mix", None, None), ("range-mix", 46, 82)]:
        output = workspace / f"{name}.wav"
        selection = [] if start is None else ["--start-frame", str(start), "--end-frame", str(end)]
        samples = 1382400 if start is None else (end - start) * 800
        result = execute([ed, "studio", "edit", "render-audio", project, "--output", output,
                          "--container", "wav", "--sample-rate", "48000", "--channels", "2", *selection, "--progress", "--json"])
        checked_report(result, output, "audio", samples, start, end)
        results[name] = execute([helper, "verify-music", output, str(samples), str(0 if start is None else start * 800)])
        (workspace / f"{name}-result.json").write_text(json.dumps({"delivery": result["audioReport"], "verification": results[name]}, indent=2) + "\n")
    for name, codec, color, extension in [("range-video", "h264", "rec709", "mp4"),
                                          ("range-master", "proRes422HQ", "displayP3", "mov")]:
        output = workspace / f"{name}.{extension}"
        result = execute([ed, "studio", "edit", "render", project, "--output", output, "--codec", codec,
                          "--color-space", color, "--audio-sample-rate", "48000", "--audio-channels", "2",
                          "--start-frame", "46", "--end-frame", "82", "--progress", "--json"])
        report = checked_report(result, output, "video", 36, 46, 82)
        require(report["videoCodec"] == ("apch" if codec == "proRes422HQ" else "avc1"), "Measured video codec mismatch")
        require(report["audioCodec"] == ("lpcm" if codec == "proRes422HQ" else "aac "), "Measured video audio codec mismatch")
        if codec == "proRes422HQ":
            require(report["bitsPerComponent"] == 10, "ProRes HQ must retain 10-bit components")
        results[name] = execute([helper, "verify-range", output, "46", "82", codec, color])
        (workspace / f"{name}-result.json").write_text(json.dumps({"delivery": report, "verification": results[name]}, indent=2) + "\n")
    require(project.read_bytes() == project_bytes, "Delivery changed the source project")
    return {"cases": results, "projectBytesUnchanged": True, "boundedProgressVerified": True}


def exercise_variable_speed(edit, workspace, fixture, helper):
    project = workspace / "variable-speed.openscreen"
    plan = workspace / "variable-speed.json"
    operations = [{"videoSettings": {"settings": {"width": 180, "height": 320,
                   "frameRateNumerator": 60, "frameRateDenominator": 1, "colorSpace": "rec709"}}}]
    for index, rate in enumerate([0.5, 1, 2, 1]):
        operations.extend([
            {"addMedia": {"path": str(fixture / f"shot-{index + 1:02d}.mov"), "name": f"shot-{index}"}},
            {"speed": {"clipID": f"shot-{index}", "rate": rate}},
        ])
    operations.append({"addAudio": {"path": str(fixture / "music.wav"), "start": 0, "offset": 0, "name": "score"}})
    plan.write_text(json.dumps({"version": 1, "operations": operations}, indent=2) + "\n")
    edit("create", project, "--title", "Synthetic variable-speed music", "--json")
    edit("apply", project, "--plan", plan, "--overwrite", "--json")
    shown = edit("show", project, "--json")
    require(len(shown["audioTracks"]) == 1 and shown["audioTracks"][0]["timebase"] == "output", "Music must be one independent output-clock track")
    before = shown["audioTracks"]
    plan.write_text(json.dumps({"version": 1, "operations": [
        {"reorder": {"clipIDs": [clip["id"] for clip in reversed(shown["timeline"]["clips"])]}}
    ]}) + "\n")
    edit("apply", project, "--plan", plan, "--overwrite", "--json")
    require(edit("show", project, "--json")["audioTracks"] == before, "Video reorder retimed independent music")
    output = workspace / "variable-speed.wav"
    result = edit("render-audio", project, "--output", output, "--sample-rate", "48000", "--channels", "2", "--progress", "--json")
    checked_report(result, output, "audio", 216000)
    verification = execute([helper, "verify-music", output, "216000"])
    report = {"delivery": result["audioReport"], "verification": verification, "rates": [0.5, 1, 2, 1], "reorderPreservedMusic": True}
    (workspace / "variable-speed-result.json").write_text(json.dumps(report, indent=2) + "\n")
    return report
