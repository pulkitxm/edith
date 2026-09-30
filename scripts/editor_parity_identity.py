import os
import pathlib
import plistlib

from editor_acceptance_contracts import require
from editor_parity_fixtures import checksum


def runtime_identity(entrypoint):
    entrypoint = pathlib.Path(os.path.abspath(entrypoint))
    resolved = entrypoint.resolve(strict=True)
    packaged = entrypoint.name == "ed" and entrypoint.parent.name == "MacOS" and entrypoint.parent.parent.name == "Contents"
    files = {"entrypoint": resolved}
    if packaged:
        contents = entrypoint.parent.parent
        launcher = contents / "Resources/ed-launcher"
        info = contents / "Info.plist"
        require(entrypoint.is_symlink() and os.readlink(entrypoint) == "../Resources/ed-launcher"
                and not launcher.is_symlink() and resolved == launcher.resolve(strict=True),
                "Packaged CLI must use the standard MacOS/ed launcher symlink")
        expected = pathlib.Path(__file__).resolve().parent.parent / "Resources/ed-launcher"
        require(launcher.read_bytes() == expected.read_bytes(), "Packaged CLI launcher does not match the fixed delegation contract")
        metadata = plistlib.loads(info.read_bytes())
        require(metadata.get("CFBundleExecutable") == "Edith", "Packaged CLI runtime must be CFBundleExecutable Edith")
        executable = contents / "MacOS" / metadata["CFBundleExecutable"]
        require(executable.is_file() and not executable.is_symlink() and not info.is_symlink(), "Packaged CLI runtime and identity must be regular bundle files")
        files.update(runtimeExecutable=executable.resolve(strict=True), bundleInfo=info.resolve(strict=True))
    else:
        require(resolved.name != "ed-launcher", "Invoke the packaged launcher through Contents/MacOS/ed")
        files["runtimeExecutable"] = resolved
    return {"entrypointPath": str(entrypoint), "packaged": packaged,
            "runtimeHashMap": {name: {"path": str(path), "sha256": checksum(path)} for name, path in files.items()}}


def verify_runtime(identity, stage):
    require(runtime_identity(identity["entrypointPath"]) == identity, f"CLI runtime identity changed {stage}")


def runtime_artifacts(identity):
    return {pathlib.Path(value["path"]): value["sha256"] for value in identity["runtimeHashMap"].values()}
