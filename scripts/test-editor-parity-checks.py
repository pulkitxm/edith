import argparse
import json
import pathlib
import subprocess
import sys

from editor_acceptance_contracts import require
from editor_parity_checks import check_aac_passthrough, check_mastered_audio, check_picture_samples, decoded_frames, measure_loudness, picture_sample_frames, protected_snapshot
from editor_parity_cli import publish_result
from editor_parity_fixtures import ffmpeg, fixture_path, verify, write_json
from editor_parity_pixels import check_caption_pixels, check_fill_pixels, check_photo_pixels, codec_control, reference_pixels


def rejects(operation, message):
    try:
        operation()
    except AssertionError as error:
        require(message in str(error), f"Unexpected negative-control failure: {error}")
    else:
        raise AssertionError("Negative control unexpectedly passed")


def main():
    parser = argparse.ArgumentParser(description="Exercise independent parity checkers with synthetic positive and negative controls")
    parser.add_argument("--fixture", required=True, type=pathlib.Path)
    parser.add_argument("--workspace", required=True, type=pathlib.Path)
    args = parser.parse_args()
    fixture = args.fixture.resolve(strict=True)
    workspace = args.workspace.absolute()
    require(not workspace.exists(), "Control workspace must not already exist")
    workspace.mkdir(parents=True)
    verify(fixture)
    manifest = json.loads((fixture / "parity-manifest.json").read_text())
    before = protected_snapshot(fixture, manifest)
    width, height, blur = 180, 320, 8
    bounds = (0.1, 0.1, 0.8, 0.15)
    color = {"brightness": 0.06, "contrast": 1.12, "saturation": 1.15}
    shot = manifest["shots"][0]
    source = fixture_path(fixture, shot["path"])
    crop = shot["sourceCrop"]
    reference = reference_pixels(source, width, height, blur=blur, source_crop=crop, **color)
    photo = check_photo_pixels(codec_control(reference, width, height), source, (shot["width"], shot["height"]),
                               width, height, blur, bounds, color, crop)
    bad = reference_pixels(source, width, height, framing="fill", source_crop=crop, **color)
    rejects(lambda: check_photo_pixels(bad, source, (shot["width"], shot["height"]), width, height, blur, bounds, color, crop),
            "Native pixels differ")
    full_shot = manifest["shots"][8]
    full_size = (full_shot["width"], full_shot["height"])
    full_source = fixture_path(fixture, full_shot["path"])
    full_reference = reference_pixels(full_source, width, height, blur=blur, **color)
    flat_patches = check_photo_pixels(codec_control(full_reference, width, height), full_source, full_size, width, height, blur, bounds, color)
    ungraded = reference_pixels(full_source, width, height, blur=blur)
    rejects(lambda: check_photo_pixels(ungraded, full_source, full_size, width, height, blur, bounds, color), "Native pixels differ")
    fill_shot = next(shot for shot in manifest["shots"] if shot["focalX"] != 0.5)
    fill_source = fixture_path(fixture, fill_shot["path"])
    fill_reference = reference_pixels(fill_source, width, height, framing="fill", focal_x=fill_shot["focalX"], focal_y=fill_shot["focalY"], **color)
    fill = check_fill_pixels(codec_control(fill_reference, width, height), fill_source, width, height, bounds,
                             color, fill_shot["focalX"], fill_shot["focalY"])
    pictures = {}
    for video in (shot for shot in manifest["shots"] if shot["kind"] == "video"):
        output = workspace / f"{video['name']}-signature-control.mp4"
        ffmpeg("-i", fixture_path(fixture, video["path"]), "-vf",
               f"trim=start_frame={video['sourceStartFrame']},setpts=PTS-STARTPTS,scale={width}:{height}:force_original_aspect_ratio=increase,crop={width}:{height}",
               "-frames:v", str(video["frames"]), "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p", output)
        selected = [source_frame - video["sourceStartFrame"] for shot, source_frame in picture_sample_frames(manifest).values() if shot["name"] == video["name"]]
        pictures.update({video["startFrame"] + frame: pixels for frame, pixels in decoded_frames(output, width, height, selected).items()})
    picture_result = check_picture_samples(pictures, manifest, width, height)
    video = next(shot for shot in manifest["shots"] if shot["kind"] == "video")
    middle = video["startFrame"] + video["frames"] // 2
    repeated = {**pictures, middle: pictures[middle - 1]}
    rejects(lambda: check_picture_samples(repeated, manifest, width, height), "repeats, skips, or freezes")
    frozen = {frame: pictures[shot["startFrame"]] for frame, (shot, _) in picture_sample_frames(manifest).items()}
    rejects(lambda: check_picture_samples(frozen, manifest, width, height), "repeats, skips, or freezes")
    caption = bytearray(reference)
    for y in range(32, 80):
        for x in range(18, 162):
            index = (y * width + x) * 3
            caption[index:index + 3] = bytes((255, 255, 255) if 43 <= y <= 66 and 38 <= x <= 140 and x % 12 < 6 else (0, 0, 0))
    caption_result = check_caption_pixels(caption, reference, width, height, bounds)
    rejects(lambda: check_caption_pixels(reference, reference, width, height, bounds), "Caption did not visibly")
    overflow = bytearray(caption)
    overflow[(12 * width + 40) * 3:(12 * width + 44) * 3] = bytes([255] * 12)
    rejects(lambda: check_caption_pixels(overflow, reference, width, height, bounds), "touches or crosses")
    rejects(lambda: publish_result(workspace, {"delivery": {"frames": 5588}}, "full"), "Every required acceptance group")
    require(not (workspace / "result.json").exists() and not (workspace / ".result.json.tmp").exists(),
            "Incomplete acceptance published a result")
    original = fixture_path(fixture, manifest["music"]["path"])
    measured = measure_loudness(original)
    master = workspace / "independent-reference-master.wav"
    gain = -16 - measured["integratedLUFS"]
    fade_start = manifest["frameCount"] / manifest["frameRate"] - 0.25
    ffmpeg("-i", original, "-af", f"volume={gain}dB,afade=t=out:st={fade_start}:d=0.25", "-c:a", "pcm_s24le", master)
    codec_reference = workspace / "independent-reference-master.m4a"
    ffmpeg("-i", master, "-c:a", "aac", "-b:a", "320k", codec_reference)
    audio = check_mastered_audio(master, original, manifest, master, codec_reference)
    codec_audio = check_mastered_audio(codec_reference, original, manifest, master, codec_reference, exact_samples=False)
    rejects(lambda: check_mastered_audio(original, original, manifest, master, codec_reference), "misses -16 LUFS")
    defects = [
        ("interior-dropout", "volume=0:enable='between(t,2,2.5)'", "interior dropout"),
        ("silent-right-channel", "pan=stereo|c0=c0|c1=0*c1", "silent channel"),
        ("wrong-right-channel", "pan=stereo|c0=c0|c1=c0", "channel waveform"),
    ]
    for name, operation, message in defects:
        draft, corrupt = workspace / f"{name}-draft.wav", workspace / f"{name}.wav"
        ffmpeg("-i", master, "-af", operation, "-c:a", "pcm_s24le", draft)
        compensate = -16 - measure_loudness(draft)["integratedLUFS"]
        ffmpeg("-i", draft, "-af", f"volume={compensate}dB", "-c:a", "pcm_s24le", corrupt)
        rejects(lambda: check_mastered_audio(corrupt, original, manifest, master, codec_reference), message)
    aac = fixture_path(fixture, manifest["passthrough"]["path"])
    copied = workspace / "packet-copy.m4a"
    ffmpeg("-i", aac, "-c:a", "copy", copied)
    packets = check_aac_passthrough(aac, copied)
    reencoded = workspace / "reencoded.m4a"
    ffmpeg("-i", aac, "-c:a", "aac", "-b:a", "128k", reencoded)
    rejects(lambda: check_aac_passthrough(aac, reencoded), "packet payloads")
    require(protected_snapshot(fixture, manifest) == before, "Independent controls changed protected fixture assets")
    result = {"independentCheckerControls": True, "productAcceptance": False, "containedPhoto": photo, "focalFill": fill,
              "captionGeometry": caption_result, "pictureSignatures": picture_result,
              "flatColorPatches": flat_patches, "masteredAudio": audio, "encodedMasteredAudio": codec_audio,
              "aacPackets": packets, "negativeControlsRejected": 12,
              "sourceAndBaselineChecksumsUnchanged": True}
    write_json(workspace / "checker-controls.json", result)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
