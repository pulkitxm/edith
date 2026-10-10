import argparse
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import uuid
import zipfile


def prepare(host, executable, output=None):
    root = pathlib.Path(output or tempfile.mkdtemp(prefix="edith-gui-fixture-")).resolve()
    if not root.name.startswith("edith-gui-fixture-"):
        raise ValueError("A uniquely named fixture directory is required")
    root.mkdir(parents=True, exist_ok=True)
    home = root / "Home"
    home.mkdir(exist_ok=True)
    application = root / "Edith.app"
    shutil.copytree(host, application)
    shutil.copy2(executable, application / "Contents/MacOS/Edith")
    binary = application / "Contents/MacOS/Edith"
    subprocess.run(["install_name_tool", "-change", "@rpath/Sparkle.framework/Versions/B/Sparkle",
        "@rpath/Sparkle.framework/Sparkle", str(binary)], check=True)
    commands = subprocess.check_output(["otool", "-l", str(binary)], text=True)
    if "path @executable_path/../Frameworks " not in commands:
        subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(binary)], check=True)
    identifier = "com.pulkit.edith.tests.gui-" + str(uuid.uuid4())
    info_path = application / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update(CFBundleIdentifier=identifier, CFBundleName="Edith GUI Fixture")
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(application)], check=True)
    payload = root / "payload/calendar"
    bundle = payload / "app.bundle/Contents"
    (bundle / "MacOS").mkdir(parents=True)
    source = pathlib.Path("Packages/EdithHost/Tests/GUIFixture/CalendarRuntime.swift").resolve()
    subprocess.run([
        "xcrun", "swiftc", "-emit-library", "-O", "-swift-version", "5",
        "-target", "arm64-apple-macos14.0", "-module-name", "GUIFixtureCalendar",
        str(source), "-o", str(bundle / "MacOS/Runtime"),
    ], check=True)
    manifest = dict(id="calendar", version="1.0.0", hostABI="edith-host-1", architecture="arm64", dependencies=[])
    (payload / "package.json").write_text(json.dumps(manifest))
    (bundle / "Info.plist").write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier="com.pulkit.edith.extensions.calendar.app",
        CFBundleExecutable="Runtime", CFBundlePackageType="BNDL",
        CFBundleShortVersionString="1.0.0", EdithHostABI="edith-host-1",
    )))
    subprocess.run(["codesign", "--force", "--sign", "-", str(bundle.parent)], check=True)
    archive = root / "calendar.zip"
    files = [p for p in payload.rglob("*") if p.is_file()]
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output_zip:
        for file in files:
            output_zip.write(file, file.relative_to(payload.parent))
    package = dict(manifest, minimumSystemVersion=14,
        downloadURL="https://github.com/pulkitxm/edith/releases/download/gui-fixture/calendar.zip",
        sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
        downloadBytes=archive.stat().st_size, installedBytes=sum(p.stat().st_size for p in files))
    (root / "packages.json").write_text(json.dumps([package]))
    (root / "fixture.json").write_text(json.dumps(dict(identifier=identifier, application=str(application), home=str(home))))
    return root


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--executable", required=True)
    parser.add_argument("--output")
    args = parser.parse_args()
    print(prepare(args.host, args.executable, args.output))
