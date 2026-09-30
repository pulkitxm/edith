import json
import pathlib
import plistlib
import subprocess
import uuid

from editor_acceptance_contracts import require
from editor_parity_checks import check_aac_passthrough, check_mastered_audio, check_project, measure_loudness, verify_artifacts
from editor_parity_fixtures import checksum, ffmpeg, fixture_path, write_json


CAPTION_BOUNDS = (80 / 2160, 2700 / 3840, 2000 / 2160, 650 / 3840)
CAPTION_EXCLUSION = (0, 2600 / 3840, 1, 1 - 2600 / 3840)


def caption_style(size):
    def rgba(red, green, blue, alpha=1):
        return {"red": red, "green": green, "blue": blue, "alpha": alpha}
    return {"canvasWidth": 2160, "canvasHeight": 3840, "fontFamily": "Arial", "fontStyle": "Bold Italic",
                 "fontSize": size, "lineAdvance": 150, "alignment": "center", "anchor": "top", "metrics": "fontBounds",
                 "x": 1080, "y": 2780, "width": 2000, "fill": rgba(1, 1, 1), "outline": {"width": 6, "color": rgba(0, 0, 0)},
                 "shadow": {"x": 8, "y": 10, "blur": 0, "strokeWidth": 8, "color": rgba(0.1, 0.1, 0.1), "strokeColor": rgba(0.1, 0.3, 0.5)},
                 "gradient": {"startY": 2600, "endY": 3200, "stops": [{"location": 0, "color": rgba(0, 0, 0, 0)},
                                                                        {"location": 1, "color": rgba(0, 0, 0)}]}}


def caption_operations(manifest, schemas):
    fields = schemas["outputCaption"]["properties"]["outputCaption"]["properties"]["style"]["properties"]
    require("fontBounds" in fields["metrics"]["enum"] and "strokeColor" in fields["shadow"]["properties"],
            "caption_style_schema_incomplete: fontBounds metrics and independent shadow strokeColor are required")
    operations, styles = [], {}
    for shot in manifest["shots"]:
        style = caption_style(shot["fontSize"])
        styles[shot["name"]] = style
        anchor = {edge: {"frame": shot[edge + "Frame"], "frameRate": {"numerator": 60, "denominator": 1}} for edge in ("start", "end")}
        operations.append({"outputCaption": {"content": shot["caption"], "anchor": anchor, "style": style}})
    return operations, styles


def independent_master(original, workspace, manifest):
    count = manifest["audioSamples"]
    measured = measure_loudness(original)
    gain = -16 - measured["integratedLUFS"]
    require(measured["truePeakDBTP"] + gain < -1.5 and measured["loudnessRangeLU"] <= 11,
            "Synthetic waveform reference requires a linear gain without peak limiting or dynamic compression")
    master, codec = workspace / "reference-master.wav", workspace / "reference-master.m4a"
    ffmpeg("-i", original, "-af", f"atrim=end_sample={count},volume={gain}dB,afade=t=out:ss={count - 12000}:ns=12000",
           "-ar", "48000", "-ac", "2", "-c:a", "pcm_s24le", master)
    ffmpeg("-i", master, "-c:a", "aac", "-b:a", "320k", codec)
    return master, codec


def master_project(edit, source, workspace, manifest, fixture, dimensions):
    before = edit("show", source, "--json")
    source_checksum = checksum(source)
    track = before["audioTracks"][0]
    result = edit("audio", "master", source, "--track", track["id"], "--duration", manifest["frameCount"] / 60,
                  "--output", workspace / "mastered", "--json")
    project, audio = pathlib.Path(result["projectPath"]), pathlib.Path(result["audioPath"])
    require(project.resolve() == (workspace / "mastered/project.openscreen").resolve()
            and audio.resolve() == (workspace / "mastered/soundtrack.wav").resolve(), "Mastering published unexpected output paths")
    require(checksum(source) == source_checksum, "Mastering modified the editable input project")
    report = result["report"]
    require(report["verified"] is True and report["originalSHA256"] == manifest["music"]["sha256"]
            and report["artifactSHA256"] == checksum(audio), "Mastering provenance does not match independently hashed source and artifact")
    protected = {source: source_checksum, project: checksum(project), audio: report["artifactSHA256"],
                 project.parent / "report.json": checksum(project.parent / "report.json"),
                 fixture_path(fixture, manifest["music"]["path"]): report["originalSHA256"]}
    for field, expected in {"sourceStartSeconds": 0, "sampleFrames": manifest["audioSamples"], "sampleRate": 48000,
                            "channels": 2, "fadeOutSeconds": 0.25, "integratedLUFS": -16, "truePeakDBTP": -1.5,
                            "loudnessRangeLU": 11, "passes": 2}.items():
        require(report["recipe"][field] == expected, f"Unexpected mastering recipe field: {field}")
    shown = edit("show", project, "--json")
    original_ids = {asset["id"] for asset in before["assets"]}
    require({asset["id"] for asset in shown["assets"]} == original_ids | {result["assetID"]}, "Mastering unexpectedly replaced or added original assets")
    asset = next(asset for asset in shown["assets"] if asset["id"] == result["assetID"])
    require(pathlib.Path(asset["edithAudioPath"]).resolve(strict=True) == audio.resolve(strict=True), "Editable soundtrack does not use its verified mastered artifact")
    project_checks = check_project(shown, manifest, fixture, dimensions, audio_asset_count=2)
    original = fixture_path(fixture, manifest["music"]["path"])
    reference, codec = independent_master(original, workspace, manifest)
    checks = check_mastered_audio(audio, original, manifest, reference, codec)
    rendered = workspace / "native-master-mix.wav"
    edit("render-audio", project, "--output", rendered, "--container", "wav", "--sample-rate", "48000", "--channels", "2", "--progress", "--json")
    stable = verify_artifacts(protected, "after native PCM render")
    native_mix = check_mastered_audio(rendered, original, manifest, reference, codec)
    return project, {"artifact": checks, "nativeMix": native_mix, "artifactStability": [stable]}, project_checks, reference, codec, protected


def aac_passthrough(edit, workspace, fixture, manifest):
    project = workspace / "packet-copy.openscreen"
    edit("create", project, "--title", "Synthetic separate AAC packet verification", "--json")
    plan = {"version": 1, "operations": [
        {"videoSettings": {"settings": {"width": 180, "height": 320, "frameRateNumerator": 60, "frameRateDenominator": 1, "colorSpace": "rec709"}}},
        {"addStill": {"path": str(fixture_path(fixture, manifest["shots"][0]["path"])), "name": "synthetic-cover", "duration": manifest["frameCount"] / 60}},
        {"addAudio": {"path": str(fixture_path(fixture, manifest["passthrough"]["path"])), "name": "synthetic-aac", "start": 0, "offset": 0}},
    ]}
    edit("apply", project, "--plan", "-", "--overwrite", "--json", stdin=json.dumps(plan))
    track = edit("show", project, "--json")["audioTracks"][0]["id"]
    before = checksum(project)
    output = workspace / "packet-copy.mp4"
    result = edit("render", project, "--output", output, "--codec", "h264", "--audio-codec", "copy", "--audio-copy-track", track,
                  "--audio-sample-rate", "48000", "--audio-channels", "2", "--progress", "--json")
    checks = check_aac_passthrough(fixture_path(fixture, manifest["passthrough"]["path"]), output)
    require(result["videoReport"]["audioPassthrough"]["packetDataAndTimingVerified"] is True
            and checksum(project) == before, "Native packet-copy report or project preservation failed")
    return checks


def lifecycle(edit, ed, project, environment, require_open):
    before = checksum(project)
    shown = edit("show", project, "--summary", "--json")
    entry = edit("register", project, "--json")
    path = entry["path"]
    receipt = None
    try:
        require(entry["registered"] is True and pathlib.Path(path).resolve(strict=True) == project.resolve(strict=True)
                and entry["projectID"] == shown["projectID"] and shown["revision"] == before,
                "Native registration did not preserve canonical project identity")
        entries = [value for value in edit("library", "--json") if pathlib.Path(value["path"]).resolve() == project.resolve(strict=True)]
        require(len(entries) == 1 and entries[0] == entry and not entry.get("errorCode"), "Native library did not expose exactly one valid registered reference")
        if require_open:
            info = ed.parent.parent / "Info.plist"
            require(ed.parent.name == "MacOS" and info.is_file(), "matching_app_required: full acceptance requires the matching development bundle's ed")
            identifier = plistlib.loads(info.read_bytes())["CFBundleIdentifier"]
            require(identifier.startswith("com.pulkit.edith.dev."), "matching_app_required: use an isolated development bundle")
            process = subprocess.run([str(ed), "studio", "edit", "open", str(project), "--timeout", "30", "--json"],
                                     capture_output=True, text=True, timeout=45, env=environment)
            if process.returncode != 0:
                detail = json.loads(process.stderr)["error"]
                raise AssertionError("matching_app_required: launch this development app once with the same EDITH_DATA_ROOT and defaults suite; "
                                     + detail["code"] + ": " + detail["message"])
            receipt = json.loads(process.stdout)
            uuid.UUID(receipt["requestID"])
            require(receipt["ok"] is True and receipt["state"] == "opened" and receipt["path"] == path
                    and receipt["projectID"] == entry["projectID"] and receipt["revision"] == before,
                    "Native open acknowledgement does not match the exact registered project revision")
    finally:
        removed = edit("unregister", project, "--json")
        require(removed["registered"] is False and checksum(project) == before, "Native lifecycle changed the project or failed to remove its test registration")
    return {"registeredAndListed": True, "unregisteredReferencePreservedProject": True,
            "openAcknowledged": receipt is not None, "openReceipt": receipt, "pending": [] if require_open else ["matchingNativeAppOpen"]}
