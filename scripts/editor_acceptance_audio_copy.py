import argparse
import json
import pathlib
import subprocess
import tempfile

from editor_acceptance_audio import digest, run


def probe(path):
    return json.loads(run("ffprobe", "-v", "error", "-select_streams", "a", "-show_streams",
                          "-show_packets", "-show_data_hash", "sha256", "-of", "json", str(path)).stdout)


def packets(value):
    keys = {"pts", "dts", "duration", "data_hash", "side_data_list"}
    return [{key: value for key, value in packet.items() if key in keys} for packet in value["packets"]]


def decoded_hash(path):
    return run("ffmpeg", "-v", "error", "-i", str(path), "-map", "0:a:0", "-c:a", "pcm_s24le",
               "-f", "hash", "-hash", "sha256", "-").stdout.strip()


def acceptance(cli, root, frames):
    duration = frames / 60
    video, approved = root / "picture.mp4", root / "approved.mp4"
    project, output = root / "synthetic.openscreen", root / "delivery.mp4"
    run("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=96x64:r=60",
        "-frames:v", str(frames), "-an", "-c:v", "libx264", "-movie_timescale", "48000", str(video))
    run("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=red:s=96x64:r=60",
        "-f", "lavfi", "-i", "aevalsrc=0.12*sin(2*PI*(220*t+2*t*t))|0.12*sin(2*PI*(330*t+3*t*t)):s=48000",
        "-t", str(duration), "-c:a", "aac", "-c:v", "libx264", "-movie_timescale", "48000", str(approved))
    original_hash = digest(approved)
    run(cli, "studio", "edit", "create", str(project), "--title", "Synthetic approved soundtrack", "--json")
    plan = root / "plan.json"
    plan.write_text(json.dumps({"version": 1, "operations": [
        {"videoSettings": {"settings": {"width": 96, "height": 64,
         "frameRateNumerator": 60, "frameRateDenominator": 1, "colorSpace": "rec709"}}},
        {"addMedia": {"path": str(video), "name": "picture"}},
        {"addAudio": {"path": str(approved), "start": 0, "offset": 0, "name": "score"}},
    ]}))
    applied = json.loads(run(cli, "studio", "edit", "apply", str(project), "--plan", str(plan),
                            "--overwrite", "--json").stdout)
    track = applied["audioAliases"]["score"][0]
    source_project = project.read_bytes()
    command = [cli, "studio", "edit", "render", str(project), "--output", str(output),
               "--audio-codec", "copy", "--audio-copy-track", track, "--json"]
    result = json.loads(run(*command).stdout)
    before, after = probe(approved), probe(output)
    assert packets(before) == packets(after)
    assert before["streams"][0]["duration_ts"] == after["streams"][0]["duration_ts"] == frames * 800
    assert decoded_hash(approved) == decoded_hash(output)
    assert result["videoReport"]["frameCount"] == frames
    assert result["videoReport"]["audioPassthrough"]["packetDataAndTimingVerified"]
    assert digest(approved) == original_hash and project.read_bytes() == source_project
    rgb = subprocess.run(["ffmpeg", "-v", "error", "-i", str(output), "-frames:v", "1",
                          "-vf", "scale=1:1", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"],
                         check=True, capture_output=True).stdout
    assert rgb[2] > rgb[0], "The native blue picture must win over the approved asset's red video"
    negative = root / "negative.mp4"
    rejected = 0
    for change in [{"gainDb": 1}, {"offsetMs": 1}, {"fadeInMs": 1}, {"fadeOutMs": 1},
                   {"rate": 1.1}, {"loop": True}, {"endMs": (duration - 0.001) * 1000}]:
        document = json.loads(source_project)
        document["audioTracks"][0].update(change)
        if "endMs" in change:
            document["audioTracks"][0].pop("outputRange", None)
        project.write_text(json.dumps(document))
        failed = subprocess.run(command[:command.index(str(output))] + [str(negative)] + command[command.index(str(output)) + 1:],
                                capture_output=True, text=True)
        assert failed.returncode != 0 and not negative.exists()
        assert json.loads(failed.stderr)["error"]["code"] == "invalid_audio_copy"
        rejected += 1
    project.write_bytes(source_project)
    for extra in [["--audio-sample-rate", "44100"], ["--start-frame", "0", "--end-frame", str(frames - 1)]]:
        negative_command = [str(negative) if value == str(output) else value for value in command] + extra
        failed = subprocess.run(negative_command, capture_output=True, text=True)
        assert failed.returncode != 0 and not negative.exists()
        rejected += 1
    assert digest(approved) == original_hash
    print(json.dumps({"fixture": "synthetic approved AAC in video container", "videoFrames": frames,
                      "audibleAudioSamples": frames * 800, "AACPackets": len(before["packets"]),
                      "lastPacketDuration": before["packets"][-1]["duration"],
                      "packetHashesTimingAndPaddingIdentical": True, "decodedPCMIdentical": True,
                      "nativePictureRetained": True, "originalsUnchanged": True,
                      "invalidRequestsRejectedBeforeOutput": rejected}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True)
    parser.add_argument("--frames", type=int, default=5588)
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="edith-aac-acceptance-") as directory:
        acceptance(str(pathlib.Path(arguments.cli).resolve()), pathlib.Path(directory), arguments.frames)
