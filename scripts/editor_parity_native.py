import atexit
import contextlib
import functools
import json
import pathlib
import subprocess
import tempfile

from editor_acceptance_contracts import require
from editor_parity_fixtures import command


@functools.lru_cache(maxsize=1)
def appearance_decoder():
    root = pathlib.Path(tempfile.gettempdir()) / "opencode"
    root.mkdir(exist_ok=True)
    directory = tempfile.TemporaryDirectory(prefix="parity-native-decoder-", dir=root)
    atexit.register(directory.cleanup)
    executable = pathlib.Path(directory.name) / "decode"
    source = pathlib.Path(__file__).with_name("editor_parity_native_decode.swift")
    command(["swiftc", "-parse-as-library", "-O", source, "-o", executable])
    return executable


@contextlib.contextmanager
def srgb_frame_stream(path, dimensions, selections):
    width, height = dimensions
    selected = sorted(selections)
    require(selected and len(set(selected)) == len(selected) and min(selected) >= 0,
            "Appearance frame selection must be nonempty, unique and nonnegative")
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen([str(appearance_decoder()), str(path), str(width), str(height), json.dumps(selected)],
                                   stdout=subprocess.PIPE, stderr=errors)
        size = width * height * 3

        def frames():
            for frame in selected:
                pixels = process.stdout.read(size)
                require(len(pixels) == size, "Native appearance decoder is missing a selected frame")
                yield frame, pixels

        try:
            yield frames()
            require(process.stdout.read(1) == b"", "Unexpected extra native appearance frame")
            require(process.wait(timeout=60) == 0, "Native appearance decoding failed")
        finally:
            process.stdout.close()
            if process.poll() is None:
                process.kill()
            process.wait()


def srgb_frames(path, width, height, selections):
    with srgb_frame_stream(path, (width, height), selections) as frames:
        return dict(frames)
