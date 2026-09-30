import array
import json
import math
import pathlib
import subprocess
import sys
from fractions import Fraction

from editor_acceptance_captions import caption_snapshot
from editor_acceptance_contracts import require
from editor_parity_fixtures import FRAME_COUNT, FRAME_RATE, SAMPLE_RATE, checksum, command, fixture_path, inventory, probe


def protected_snapshot(directory, manifest):
    return {entry["path"]: checksum(fixture_path(directory, entry["path"])) for entry in inventory(directory, manifest)} | {
        "parity-manifest.json": checksum(directory / "parity-manifest.json")}


def check_project(project, manifest, fixture, dimensions):
    clips = project["timeline"]["clips"]
    assets = {asset["id"]: asset for asset in project["assets"]}
    require(len(clips) == len({clip["id"] for clip in clips}) == len({clip["assetId"] for clip in clips}) == 47,
            "Project must retain 47 distinct editable clips and original asset identities")
    require(len(assets) == 48, "Project must contain exactly 47 visual originals and one soundtrack, with no baked replacements")
    for clip, shot in zip(clips, manifest["shots"]):
        actual = pathlib.Path(assets[clip["assetId"]]["originalPath"]).resolve(strict=True)
        require(actual == fixture_path(fixture, shot["path"]), "Editable clip does not reference its exact original source")
        require(abs(clip["sourceStartSec"]) < 1e-10, "Unexpected source trim start")
        require(abs(clip["sourceEndSec"] * FRAME_RATE - shot["frames"]) < 1e-7, "Incorrect source trim endpoint")
        require(abs(clip["timelineStartSec"] * FRAME_RATE - shot["startFrame"]) < 1e-7, "Incorrect shot boundary")
    settings = project["edithVideoSettings"]
    require((settings["width"], settings["height"]) == dimensions, "Project canvas dimensions changed")
    require(Fraction(settings["frameRateNumerator"], settings["frameRateDenominator"]) == FRAME_RATE, "Project cadence changed")
    tracks = project["audioTracks"]
    require(len(tracks) == 1, "Soundtrack must remain one continuous editable track")
    track = tracks[0]
    require(track["timebase"] == "output" and abs(track["startMs"]) < 1e-9 and abs(track.get("offsetMs", 0)) < 1e-9,
            "Soundtrack must start at zero on the output clock")
    require(abs(track["endMs"] - FRAME_COUNT * 1000 / FRAME_RATE) < 1e-7 and not track.get("muted", False),
            "Soundtrack must cover the complete project")
    require(pathlib.Path(assets[track["assetId"]]["originalPath"]).resolve(strict=True) == fixture_path(fixture, manifest["music"]["path"]),
            "Soundtrack must reference its original synthetic waveform")
    return {"editableOriginals": 47, "originalPhotos": 42, "exactShotBoundaries": True, "continuousOutputClockTracks": 1}


def check_captions(report, manifest):
    snapshot = caption_snapshot(report)
    require(len(snapshot) == 47, "Project must retain 47 distinct captions")
    captions = sorted(report["captions"], key=lambda value: value["startSeconds"])
    for caption, shot in zip(captions, manifest["shots"]):
        require(snapshot[caption["id"]][:2] == (Fraction(shot["startFrame"], 60), Fraction(shot["endFrame"], 60)),
                "Caption boundaries differ from exact half-open shot boundaries")
        require(caption["content"] == shot["caption"], "Unexpected caption text or ordering")
    return {"captions": 47, "exactAnchors": True,
            "frameIntervals": [[shot["startFrame"], shot["endFrame"]] for shot in manifest["shots"]]}


def decoded_frames(path, width, height, frame_numbers):
    require(frame_numbers and len(set(frame_numbers)) == len(frame_numbers), "Frame selection must be nonempty and unique")
    expression = "+".join(f"eq(n\\,{frame})" for frame in sorted(frame_numbers))
    data = command(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-i", path,
                    "-vf", f"select={expression},scale={width}:{height}:flags=lanczos", "-fps_mode", "passthrough",
                    "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"])
    size = width * height * 3
    require(len(data) == size * len(frame_numbers), "Delivery did not decode every requested frame")
    return {frame: data[index * size:(index + 1) * size] for index, frame in enumerate(sorted(frame_numbers))}


def check_video(path, dimensions):
    metadata = probe(path)
    videos = [stream for stream in metadata["streams"] if stream["codec_type"] == "video"]
    audios = [stream for stream in metadata["streams"] if stream["codec_type"] == "audio"]
    require(len(videos) == len(audios) == 1, "Delivery must have exactly one video stream and one mastered soundtrack")
    video, audio = videos[0], audios[0]
    require((video["width"], video["height"]) == dimensions and Fraction(video["avg_frame_rate"]) == FRAME_RATE,
            "Independent delivery dimensions or cadence mismatch")
    frames = json.loads(command(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_frames",
                                "-show_entries", "frame=best_effort_timestamp", "-of", "json", path]))["frames"]
    require(len(frames) == FRAME_COUNT, "Independent decoded frame count mismatch")
    timebase = Fraction(video["time_base"])
    require(all(Fraction(frame["best_effort_timestamp"]) * timebase == Fraction(index, FRAME_RATE)
                for index, frame in enumerate(frames)), "Delivery contains a repeated, missing, or shifted frame timestamp")
    require(abs(float(video["duration"]) - FRAME_COUNT / FRAME_RATE) < 1e-6, "Independent duration mismatch")
    require(audio["codec_name"] == "aac" and int(audio["sample_rate"]) == SAMPLE_RATE and audio["channels"] == 2,
            "Independent soundtrack codec, rate, or channel mismatch")
    require(abs(float(audio["start_time"])) < 1 / SAMPLE_RATE, "Soundtrack starts after frame zero")
    require(abs(float(audio["duration"]) - FRAME_COUNT / FRAME_RATE) <= 1024 / SAMPLE_RATE,
            "Encoded soundtrack does not cover the timeline within one AAC packet")
    return {"width": video["width"], "height": video["height"], "decodedFrames": len(frames), "fps": FRAME_RATE,
            "durationSeconds": float(video["duration"]), "sha256": checksum(path), "exactTimestamps": True}


def audio_samples(path):
    data = command(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-i", path,
                    "-vn", "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "f32le", "pipe:1"])
    samples = array.array("f")
    samples.frombytes(data)
    if sys.byteorder != "little":
        samples.byteswap()
    require(all(math.isfinite(value) for value in samples), "Audio contains nonfinite samples")
    return samples


def measure_loudness(path):
    result = subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-i", str(path), "-vn", "-af",
                             "loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"],
                            capture_output=True, text=True, timeout=1800)
    require(result.returncode == 0, f"Independent loudness analysis failed: {result.stderr}")
    begin = result.stderr.rfind("{\n")
    require(begin >= 0, "Independent loudness report is missing")
    report, _ = json.JSONDecoder().raw_decode(result.stderr[begin:])
    values = {"integratedLUFS": float(report["input_i"]), "truePeakDBTP": float(report["input_tp"]),
              "loudnessRangeLU": float(report["input_lra"])}
    require(all(math.isfinite(value) for value in values.values()), "Independent loudness measurement is not finite")
    return values


def check_mastered_audio(path, original, manifest, exact_samples=True):
    loudness = measure_loudness(path)
    require(abs(loudness["integratedLUFS"] + 16) <= 0.3, "Mastered soundtrack misses -16 LUFS by more than 0.3 LU")
    require(loudness["truePeakDBTP"] <= -1.5 + 0.1, "Mastered soundtrack exceeds -1.5 dBTP with 0.1 dB measurement tolerance")
    require(loudness["loudnessRangeLU"] <= 11 + 0.3, "Mastered soundtrack exceeds the 11 LU range target")
    source, actual = audio_samples(original), audio_samples(path)
    count = FRAME_COUNT * 800
    require(len(source) == count and (len(actual) == count if exact_samples else abs(len(actual) - count) < 1024),
            "Mastered audio sample count mismatch")
    require(len(actual) >= count, "Mastered audio truncates the final fade")
    correlations = []
    for boundary in [shot["startFrame"] * 800 for shot in manifest["shots"]]:
        start, end = max(0, boundary - 240), min(count - 12000, boundary + 240)
        a, b = source[start:end], actual[start:end]
        energy_a, energy_b = sum(value * value for value in a), sum(value * value for value in b)
        require(energy_a > 0 and energy_b > 0, "Soundtrack contains an unexpected gap at a shot boundary")
        correlation = sum(left * right for left, right in zip(a, b)) / math.sqrt(energy_a * energy_b)
        require(correlation > 0.985, "Soundtrack source position or waveform changes at a shot boundary")
        correlations.append(correlation)
    fade_start = count - 12000

    def gain(start, end):
        a, b = source[start:end], actual[start:end]
        return sum(left * right for left, right in zip(a, b)) / sum(value * value for value in a)

    reference_gain = gain(fade_start - 4800, fade_start)
    require(reference_gain > 0, "Invalid pre-fade soundtrack gain")
    fade = []
    for index in range(25):
        start = fade_start + index * 480
        measured = gain(start, start + 480) / reference_gain
        expected = 1 - (index + 0.5) / 25
        require(abs(measured - expected) <= 0.06, "Final soundtrack fade differs from the requested linear 0.25 seconds")
        fade.append(measured)
    return {**loudness, "samples": len(actual), "minimumBoundaryCorrelation": min(correlations),
            "boundaryChecks": len(correlations), "fadeOutSeconds": 0.25, "fadeWindowGains": fade}


def aac_packets(path):
    value = json.loads(command(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_packets", "-show_streams",
                               "-show_data_hash", "sha256", "-of", "json", path]))
    require(len(value["streams"]) == 1 and value["streams"][0]["codec_name"] == "aac", "Packet passthrough requires AAC")
    stream = value["streams"][0]
    packets = value["packets"]
    require(packets and all("data_hash" in packet for packet in packets), "AAC packet payload hashes are missing")
    return stream, packets


def check_aac_passthrough(original, delivery):
    source, source_packets = aac_packets(original)
    target, target_packets = aac_packets(delivery)
    for field in ("sample_rate", "channels", "profile", "extradata_hash"):
        require(source[field] == target[field], f"AAC passthrough changed codec configuration: {field}")
    require([packet["data_hash"] for packet in source_packets] == [packet["data_hash"] for packet in target_packets],
            "AAC compressed packet payloads were changed, dropped, or duplicated")
    source_base, target_base = Fraction(source["time_base"]), Fraction(target["time_base"])
    for left, right in zip(source_packets, target_packets):
        for field in ("pts", "dts", "duration"):
            require(int(left[field]) * source_base == int(right[field]) * target_base, f"AAC passthrough changed {field}")
    return {"packets": len(source_packets), "compressedPayloadsIdentical": True, "packetTimingIdentical": True,
            "codecConfigurationIdentical": True}
