import argparse
import os
import stat
import subprocess
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

parser = argparse.ArgumentParser()
parser.add_argument("--app", default="local/minimal-host/Edith.app")
parser.add_argument("--package", default="dist/extensions/lidAwake.zip")
parser.add_argument("--callback-bundle")
args = parser.parse_args()
assert os.geteuid() != 0, "Run the synthetic privileged fixture without root privileges"
app = Path(args.app).resolve()
harness = Path(__file__).resolve().parent.parent / "Packages/EdithHost/Tests/EdithHostCoreTests/Fixtures/privileged-lifecycle.py"
role = PurePosixPath("lidAwake/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/lidAwake/privileged.bundle")


def verify(bundle):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, capture_output=True)
    subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True, capture_output=True)
    subprocess.run(["/usr/bin/python3", "-B", str(harness), "--app", str(app), "--bundle", str(bundle)], check=True)


if args.callback_bundle:
    verify(Path(args.callback_bundle).resolve())
else:
    with tempfile.TemporaryDirectory(prefix="privileged-extension-fixture-") as directory:
        fixture = Path(directory).resolve()
        with zipfile.ZipFile(Path(args.package).resolve()) as package:
            entries = package.infolist()
            assert len(entries) <= 10_000
            assert sum(entry.file_size for entry in entries) <= 256 * 1024 * 1024
            for entry in entries:
                path = PurePosixPath(entry.filename)
                assert not path.is_absolute() and ".." not in path.parts
                assert len(entry.filename.encode()) <= 4096
                assert not stat.S_ISLNK(entry.external_attr >> 16)
                assert path.parts and path.parts[0] == "lidAwake"
            package.extractall(fixture)
        bundle = fixture.joinpath(*role.parts)
        assert bundle.is_dir(), "The fixture requires the current nested ABI2 privileged role"
        assert not (fixture / "lidAwake/privileged.bundle").exists(), "Flat ABI1 fixture payloads are rejected"
        verify(bundle)
