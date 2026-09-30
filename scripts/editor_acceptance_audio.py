import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import tempfile


def run(*arguments):
    return subprocess.run(arguments, check=True, capture_output=True, text=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mastering(cli, root):
    video = root / "synthetic-video.mp4"
    source = root / "synthetic-score.wav"
    project = root / "synthetic.openscreen"
    bundle = root / "mastered"
    run("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=navy:s=96x64:r=60",
        "-frames:v", "5588", "-an", "-c:v", "libx264", "-movie_timescale", "48000", str(video))
    run("ffmpeg", "-v", "error", "-f", "lavfi", "-i",
        "aevalsrc=0.12*sin(2*PI*(220*t+2*t*t))|0.12*sin(2*PI*(330*t+3*t*t)):s=48000:d=94",
        "-c:a", "pcm_s24le", str(source))
    original_hash = digest(source)
    run(cli, "studio", "edit", "create", str(project), "--title", "Synthetic soundtrack", "--json")
    plan = root / "plan.json"
    plan.write_text(json.dumps({"version": 1, "operations": [
        {"addMedia": {"path": str(video), "name": "picture"}},
        {"addAudio": {"path": str(source), "start": 0, "offset": 0, "name": "score"}},
    ]}))
    applied = json.loads(run(cli, "studio", "edit", "apply", str(project), "--plan", str(plan),
                            "--overwrite", "--json").stdout)
    track = applied["audioAliases"]["score"][0]
    project_hash = digest(project)
    command = [cli, "studio", "edit", "audio", "master", str(project), "--track", track,
               "--duration", format(5588 / 60, ".9f"), "--output", str(bundle), "--json"]
    result = json.loads(run(*command).stdout)
    assert digest(source) == original_hash and digest(project) == project_hash
    assert result["report"]["verified"]
    assert result["report"]["recipe"]["sampleFrames"] == 4_470_400
    audio = bundle / "soundtrack.wav"
    probe = json.loads(run("ffprobe", "-v", "error", "-show_streams", "-of", "json", str(audio)).stdout)
    stream = probe["streams"][0]
    assert stream["codec_name"] == "pcm_s24le"
    assert stream["sample_rate"] == "48000" and stream["channels"] == 2
    assert stream["duration_ts"] == 4_470_400
    independent = run("ffmpeg", "-hide_banner", "-nostats", "-i", str(audio),
                      "-af", "ebur128=peak=true", "-f", "null", "-").stderr.split("Summary:")[-1]
    integrated = float(re.search(r"I:\s*([-\d.]+) LUFS", independent)[1])
    peak = float(re.search(r"Peak:\s*([-\d.]+) dBFS", independent)[1])
    loudness_range = float(re.search(r"LRA:\s*([-\d.]+) LU", independent)[1])
    assert abs(integrated + 16) <= 0.3 and peak <= -1.4 and loudness_range <= 11.5
    run(cli, "studio", "edit", "validate", str(bundle / "project.openscreen"), "--json")
    duplicate = subprocess.run(command, capture_output=True, text=True)
    assert duplicate.returncode != 0
    assert digest(audio) == result["report"]["artifactSHA256"]
    assert digest(source) == original_hash and digest(project) == project_hash
    print(json.dumps({"fixture": "synthetic 5588/60-second soundtrack", "sampleFrames": 4_470_400,
                      "sampleRate": 48000, "channels": 2, "integratedLUFS": integrated,
                      "truePeakDBTP": peak, "loudnessRangeLU": loudness_range,
                      "originalMediaUnchanged": True, "originalProjectUnchanged": True,
                      "duplicateDestinationRejected": True, "registeredProjectValidated": True}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True)
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="edith-audio-acceptance-") as directory:
        mastering(str(pathlib.Path(arguments.cli).resolve()), pathlib.Path(directory))
