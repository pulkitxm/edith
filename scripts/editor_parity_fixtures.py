import argparse
import hashlib
import json
import pathlib
import random
import subprocess
import sys

from editor_acceptance_contracts import require


FRAME_COUNT = 5588
FRAME_RATE = 60
SAMPLE_RATE = 48000
VIDEO_INDICES = {6, 16, 26, 36, 46}
PHOTO_INDICES = [index for index in range(47) if index not in VIDEO_INDICES]
CONTAIN_INDICES = {PHOTO_INDICES[index * 42 // 18] for index in range(18)}
FOCAL_INDICES = [index for index in PHOTO_INDICES if index not in CONTAIN_INDICES][:2]


def shot_specifications():
    generator = random.Random(5588)
    durations = [43, 442, *(generator.randint(65, 155) for _ in range(45))]
    adjustment = FRAME_COUNT - sum(durations)
    while adjustment:
        index = generator.randrange(2, 47)
        change = 1 if adjustment > 0 else -1
        if 44 <= durations[index] + change <= 441:
            durations[index] += change
            adjustment -= change
    words = ["Amber", "Meadow", "Orbit", "Pebble", "Lantern", "Willow", "Coral", "Harbor", "Cobalt", "Garden", "Silver", "Valley"]
    specifications = []
    for index, frames in enumerate(durations):
        caption = " ".join(generator.sample(words, 2)) + f" {index + 1:02d}"
        if index in {8, 19, 30, 41}:
            caption += "\n" + " ".join(generator.sample(words, 2))
        shot = {"frames": frames, "caption": caption, "fontSize": 112 if index in {45, 46} else 104,
                "framing": "contain" if index in CONTAIN_INDICES else "fill", "focalX": 0.5, "focalY": 0.5}
        if index in FOCAL_INDICES:
            shot.update({"focalX": 0.3 if index == FOCAL_INDICES[0] else 0.7, "focalY": 0.35 if index == FOCAL_INDICES[0] else 0.65})
        if index == min(CONTAIN_INDICES):
            shot["sourceCrop"] = {"x": 0.1, "y": 0.15, "width": 0.8, "height": 0.7}
        specifications.append(shot)
    return specifications


def checksum(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def command(arguments, data=None):
    result = subprocess.run([str(value) for value in arguments], input=data, capture_output=True, timeout=1800)
    require(result.returncode == 0, f"Command failed ({result.returncode}): {result.stderr.decode(errors='replace')}")
    return result.stdout


def ffmpeg(*arguments, data=None):
    return command(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-n", *arguments], data)


def probe(path):
    return json.loads(command(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", path]))


def pixels(index, width, height):
    color = ((index * 43 + 51) % 176 + 40, (index * 67 + 27) % 176 + 40, (index * 89 + 13) % 176 + 40)
    data = bytearray()
    for y in range(height):
        for x in range(width):
            if y < height // 12:
                value = (240, 32, 48)
            elif y >= height * 11 // 12:
                value = (32, 64, 240)
            elif x < width // 16:
                value = (32, 224, 64)
            elif x >= width * 15 // 16:
                value = (240, 208, 32)
            elif height // 3 <= y < height * 2 // 3 and width // 4 <= x < width * 3 // 4:
                value = color
            else:
                level = 24 if (x // 24 + y // 24) % 2 else -24
                value = tuple(channel + level for channel in color)
            data.extend(value)
    return bytes(data), color


def generate(directory):
    require(not directory.exists(), "Fixture directory must not already exist")
    directory.mkdir(parents=True)
    originals = directory / "originals"
    originals.mkdir()
    baselines = directory / "baseline-exports"
    baselines.mkdir()
    shots = []
    start = 0
    for index, specification in enumerate(shot_specifications()):
        photo = index in PHOTO_INDICES
        width, height = (960, 540) if photo else (320, 180)
        raw, color = pixels(index, width, height)
        path = originals / f"source-{index + 1:02d}{'.png' if photo else '.mp4'}"
        source = ["-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", f"{width}x{height}", "-framerate", "60", "-i", "pipe:0"]
        if photo:
            ffmpeg(*source, "-frames:v", "1", "-update", "1", path, data=raw)
        else:
            source_frames = specification["frames"] + 2
            ffmpeg(*source, "-vf", f"loop=loop={source_frames - 1}:size=1:start=0", "-frames:v", str(source_frames), "-c:v", "libx264", "-preset", "ultrafast",
                   "-crf", "12", "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", path, data=raw)
        frames = specification["frames"]
        shots.append({"name": f"synthetic-{index + 1:02d}", "path": str(path.relative_to(directory)), "sha256": checksum(path),
                      "kind": "photo" if photo else "video", "width": width, "height": height, "centerRGB": color,
                      "startFrame": start, "endFrame": start + frames, "frames": frames,
                      "sourceStartFrame": 0, **specification})
        start += frames
    music = originals / "synthetic-music.wav"
    expression = "(0.08+0.025*sin(2*PI*t/7))*(sin(2*PI*220*t)+0.5*sin(2*PI*330*t)+0.25*sin(2*PI*550*t))"
    ffmpeg("-f", "lavfi", "-i", f"aevalsrc={expression}|{expression}:s=48000", "-af", f"atrim=end_sample={FRAME_COUNT * 800}",
           "-c:a", "pcm_s24le", music)
    aac = originals / "synthetic-passthrough.m4a"
    ffmpeg("-i", music, "-c:a", "aac", "-b:a", "192k", aac)
    baseline = []
    for index in range(6):
        path = baselines / f"canonical-{index + 1}.mp4"
        ffmpeg("-f", "lavfi", "-i", f"color=c=0x{index + 2:02x}5070:s=90x160:r=60", "-frames:v", str(12 + index),
               "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", path)
        baseline.append({"path": str(path.relative_to(directory)), "sha256": checksum(path)})
    manifest = {"version": 1, "synthetic": True, "frameCount": FRAME_COUNT, "frameRate": FRAME_RATE,
                "width": 2160, "height": 3840, "audioSampleRate": SAMPLE_RATE, "audioSamples": FRAME_COUNT * 800,
                "shots": shots, "music": {"path": str(music.relative_to(directory)), "sha256": checksum(music)},
                "passthrough": {"path": str(aac.relative_to(directory)), "sha256": checksum(aac)}, "baselineExports": baseline,
                "mastering": {"integratedLUFS": -16, "truePeakDBTP": -1.5, "loudnessRangeLU": 11, "fadeOutSeconds": 0.25}}
    write_json(directory / "parity-manifest.json", manifest)
    return verify(directory)


def fixture_path(directory, relative):
    path = (directory / relative).resolve(strict=True)
    require(path.is_relative_to(directory.resolve(strict=True)), "Fixture reference escapes the isolated directory")
    return path


def inventory(directory, manifest):
    return [*manifest["shots"], manifest["music"], manifest["passthrough"], *manifest["baselineExports"]]


def verify(directory, media=True):
    directory = directory.resolve(strict=True)
    manifest = json.loads((directory / "parity-manifest.json").read_text())
    require(manifest["version"] == 1 and manifest["synthetic"] is True, "Unsupported synthetic fixture manifest")
    require((manifest["frameCount"], manifest["frameRate"], manifest["width"], manifest["height"]) == (5588, 60, 2160, 3840),
            "Fixture delivery target changed")
    shots = manifest["shots"]
    require(len(shots) == 47 and len({shot["sha256"] for shot in shots}) == 47, "Expected 47 distinct original sources")
    require(sum(shot["kind"] == "photo" for shot in shots) == 42 and sum(shot["kind"] == "video" for shot in shots) == 5,
            "Expected five video and 42 photo originals")
    require(sum(shot["framing"] == "contain" for shot in shots) == 18
            and sum(shot["kind"] == "photo" and shot["framing"] == "fill" for shot in shots) == 24,
            "Expected 18 contained and 24 fill photos")
    require(sum("sourceCrop" in shot for shot in shots) == 1 and sum(shot["focalX"] != 0.5 for shot in shots) == 2,
            "Expected one source crop and two noncenter focal points")
    require(sum("\n" in shot["caption"] for shot in shots) == 4 and sum(shot["fontSize"] == 104 for shot in shots) == 45
            and sum(shot["fontSize"] == 112 for shot in shots) == 2, "Caption line or font-size distribution changed")
    require(min(shot["frames"] for shot in shots) == 43 and max(shot["frames"] for shot in shots) == 442,
            "Expected independently generated shot durations spanning 43 through 442 frames")
    require(len(manifest["baselineExports"]) == 6, "Expected six canonical synthetic baseline exports")
    entries = inventory(directory, manifest)
    require(len({entry["path"] for entry in entries}) == len(entries), "Duplicate fixture paths")
    for entry in entries:
        path = fixture_path(directory, entry["path"])
        require(checksum(path) == entry["sha256"], f"Protected synthetic source changed: {entry['path']}")
    position = 0
    for index, shot in enumerate(shots):
        require(shot["startFrame"] == position and shot["frames"] == shot["endFrame"] - position,
                "Shot boundaries contain a gap, overlap, or incorrect duration")
        require(shot["sourceStartFrame"] == 0 and all(shot[key] == value for key, value in shot_specifications()[index].items()),
                "Unexpected synthetic shot identity")
        position = shot["endFrame"]
        if media:
            stream = probe(fixture_path(directory, shot["path"]))["streams"][0]
            require((stream["width"], stream["height"]) == (shot["width"], shot["height"]), "Source dimensions changed")
            if shot["kind"] == "video":
                require(stream["r_frame_rate"] == "60/1" and int(stream["nb_frames"]) == shot["frames"] + 2, "Incorrect synthetic video cadence")
    require(position == FRAME_COUNT and manifest["audioSamples"] == FRAME_COUNT * 800, "Incorrect fixture frame or sample grid")
    if media:
        stream = probe(fixture_path(directory, manifest["music"]["path"]))["streams"][0]
        require(int(stream["sample_rate"]) == SAMPLE_RATE and stream["channels"] == 2
                and int(stream["duration_ts"]) == manifest["audioSamples"], "Synthetic music must cover every output sample")
    return {"fixtureVerified": True, "originals": 47, "videos": 5, "photos": 42, "containedPhotos": 18, "fillPhotos": 24, "frames": FRAME_COUNT,
            "durationSeconds": FRAME_COUNT / FRAME_RATE, "baselineExports": 6, "protectedFiles": len(entries)}


def main():
    parser = argparse.ArgumentParser(description="Generate or verify isolated 47-original editor parity fixtures")
    parser.add_argument("action", choices=["generate", "verify"])
    parser.add_argument("directory", type=pathlib.Path)
    arguments = parser.parse_args()
    result = generate(arguments.directory.absolute()) if arguments.action == "generate" else verify(arguments.directory)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
