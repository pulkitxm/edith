import argparse
import pathlib
import plistlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--application", default="com.pulkit.edith")
parser.add_argument("--version", default="1.0")
parser.add_argument("--identity", default="-")
parser.add_argument("--output", type=pathlib.Path, required=True)
parser.add_argument("--test", action="store_true")
parser.add_argument("--driver", type=pathlib.Path)
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
source = root / "Extensions/virtualCamera/NativeRuntime/Sources/MeetingMicrophone"
tests = root / "Extensions/virtualCamera/NativeRuntime/Tests/MeetingMicrophoneTests/EdithMicrophoneTests.cpp"
args.output.mkdir(parents=True, exist_ok=True)
if args.test:
    binary = args.output / "microphone-tests"
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                    "-I", str(source), str(tests), "-framework", "CoreAudio",
                    "-framework", "CoreFoundation", "-o", str(binary)], check=True)
    subprocess.run([str(binary)] + ([str(args.driver)] if args.driver else []), check=True)
    raise SystemExit(0)
uid = args.application + ".microphone"
slot = args.application.removeprefix("com.pulkit.edith.dev.")
name = "Edith Microphone" if args.application == "com.pulkit.edith" else f"Edith Microphone ({slot})"
factory = "1A9DB29B-7D06-41B3-921F-244565DD86D9"
driver = args.output / (uid + ".driver")
executable = driver / "Contents/MacOS/EdithMicrophone"
executable.parent.mkdir(parents=True)
info = {"CFBundleIdentifier": uid, "CFBundleName": name, "CFBundleExecutable": "EdithMicrophone",
        "CFBundlePackageType": "BNDL", "CFBundleShortVersionString": args.version,
        "CFBundleVersion": args.version, "CFPlugInDynamicRegistration": False,
        "CFPlugInFactories": {factory: "EdithMicrophoneFactory"},
        "CFPlugInTypes": {"443ABAB8-E7B3-491A-B985-BEB9187030DB": [factory]}}
with (driver / "Contents/Info.plist").open("wb") as handle:
    plistlib.dump(info, handle)
subprocess.run(["xcrun", "clang++", "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror",
                "-arch", "arm64", "-mmacosx-version-min=14.0", "-bundle",
                "-fvisibility=hidden", f'-DEDITH_MICROPHONE_UID="{uid}"',
                f'-DEDITH_MICROPHONE_NAME="{name}"', str(source / "EdithMicrophone.cpp"),
                "-framework", "CoreAudio", "-framework", "CoreFoundation", "-o", str(executable)], check=True)
subprocess.run(["codesign", "--force", "--sign", args.identity, "--options", "runtime", str(driver)], check=True)
