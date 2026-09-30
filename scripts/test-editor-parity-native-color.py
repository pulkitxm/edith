import argparse
import json
import os
import pathlib
import struct
import uuid

from editor_acceptance_contracts import require
from editor_parity_checks import decoded_frames
from editor_parity_cli import invoke
from editor_parity_fixtures import checksum, command, ffmpeg, write_json
from editor_parity_identity import runtime_identity, verify_runtime
from editor_parity_native import srgb_frames
from editor_parity_pixels import difference, image_pixels


def system_709_gamma():
    profile = command(["swift", "-e", "import CoreVideo; import CoreGraphics; import Foundation; "
                       "let tags = [\"CVImageBufferColorPrimaries\": \"ITU_R_709_2\", "
                       "\"CVImageBufferTransferFunction\": \"ITU_R_709_2\", "
                       "\"CVImageBufferYCbCrMatrix\": \"ITU_R_709_2\"] as CFDictionary; "
                       "let space = CVImageBufferCreateColorSpaceFromAttachments(tags)!.takeRetainedValue(); "
                       "FileHandle.standardOutput.write(space.copyICCData()! as Data)"])
    count = struct.unpack_from(">I", profile, 128)[0]
    curves = []
    for index in range(count):
        tag, offset, size = struct.unpack_from(">4sII", profile, 132 + index * 12)
        if tag in {b"rTRC", b"gTRC", b"bTRC"}:
            curve = profile[offset:offset + size]
            require(curve[:4] == b"curv" and struct.unpack_from(">I", curve, 8)[0] == 1,
                    "System HDTV profile no longer exposes a single-gamma tone curve")
            curves.append(struct.unpack_from(">H", curve, 12)[0] / 256)
    require(len(curves) == 3 and len(set(curves)) == 1, "System HDTV profile has unequal RGB tone curves")
    return curves[0]


def gamma_to_srgb(pixels, gamma):
    def channel(code):
        linear = (code / 255) ** gamma
        encoded = 12.92 * linear if linear <= 0.0031308 else 1.055 * linear ** (1 / 2.4) - 0.055
        return round(encoded * 255)
    table = bytes(channel(code) for code in range(256))
    return pixels.translate(table)


def main():
    parser = argparse.ArgumentParser(description="Synthetic native export appearance and frame-selection controls")
    parser.add_argument("--ed", type=pathlib.Path, required=True)
    parser.add_argument("--workspace", type=pathlib.Path, required=True)
    args = parser.parse_args()
    workspace = args.workspace.absolute()
    require(not workspace.exists(), "Native color workspace must be new")
    workspace.mkdir(parents=True)
    identity = runtime_identity(args.ed)
    environment = {**os.environ, "EDITH_DATA_ROOT": str(workspace / "runtime"),
                   "EDITH_SHARED_DEFAULTS_SUITE": f"com.pulkit.edith.native-color.{uuid.uuid4().hex}"}
    ed = pathlib.Path(identity["entrypointPath"])

    def edit(*arguments, **options):
        return invoke(ed, *arguments, environment=environment, **options)

    width, height = 128, 96
    patches = [(0, 0, 0), (32, 32, 32), (64, 64, 64), (128, 128, 128),
               (192, 192, 192), (255, 255, 255), (72, 120, 168), (176, 112, 64)]
    sources = []
    expected = []
    for index, colors in enumerate((patches, list(reversed(patches)))):
        pixels = bytes(channel for y in range(height) for x in range(width)
                       for channel in colors[(y // 48) * 4 + x // 32])
        source = workspace / f"synthetic-swatches-{index}.png"
        ffmpeg("-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", f"{width}x{height}", "-i", "pipe:0",
               "-frames:v", "1", "-update", "1", source, data=pixels)
        command(["sips", "--embedProfile", "/System/Library/ColorSync/Profiles/sRGB Profile.icc", source])
        sources.append(source)
        expected.append(pixels)
    original = {source: checksum(source) for source in sources}
    indices = [(y * width + x) * 3 for row in range(2) for column in range(4)
               for y in range(row * 48 + 8, row * 48 + 40, 4)
               for x in range(column * 32 + 8, column * 32 + 24, 4)]
    checks = []
    for color, codec in (("rec709", "h264"), ("rec709", "proRes4444"), ("displayP3", "proRes4444")):
        name = f"{color}-{codec}"
        project = workspace / f"{name}.openscreen"
        edit("create", project, "--title", "Synthetic neutral color controls", "--json")
        operations = [{"videoSettings": {"settings": {"width": width, "height": height,
                       "frameRateNumerator": 60, "frameRateDenominator": 1, "colorSpace": color}}}]
        operations.extend({"addStill": {"path": str(source), "name": f"swatches-{index}", "duration": 3 / 60}}
                          for index, source in enumerate(sources))
        edit("apply", project, "--plan", "-", "--overwrite", "--json", stdin=json.dumps({"version": 1, "operations": operations}))
        before = checksum(project)
        delivery = workspace / f"{name}.{'mp4' if codec == 'h264' else 'mov'}"
        report = edit("render", project, "--output", delivery, "--codec", codec, "--bit-rate", "8000000", "--json")
        require(report["videoReport"]["colorPrimaries"] == ("ITU_R_709_2" if color == "rec709" else "P3_D65")
                and report["videoReport"]["transferFunction"] == ("ITU_R_709_2" if color == "rec709" else "IEC_sRGB"),
                "Native delivery did not declare its selected color contract")
        decoded = srgb_frames(delivery, width, height, [0, 2, 3, 5])
        frames = []
        for frame, actual in decoded.items():
            reference = expected[frame // 3]
            measurement = difference(actual, reference, indices)
            require(measurement["meanAbsoluteError"] <= 2, "Neutral source appearance changed beyond the fixed two-code budget")
            preview = workspace / f"{name}-preview-{frame}.png"
            edit("frame", project, "--frame", frame, "--output", preview, "--json")
            preview_check = difference(image_pixels(preview, width, height), reference, indices)
            require(preview_check["meanAbsoluteError"] <= 2, "Neutral preview changed beyond the fixed two-code budget")
            wrong = difference(actual, expected[1 - frame // 3], indices)
            require(wrong["meanAbsoluteError"] > 40, "Frame selection control cannot distinguish the two synthetic sources")
            frames.append({"frame": frame, "delivery": measurement, "preview": preview_check})
        check = {"colorSpace": color, "codec": codec, "nativeReport": report["videoReport"], "frames": frames}
        reduced = srgb_frames(delivery, width // 2, height // 2, [0])[0]
        reduced_indices = [((offset // 3 // width // 2) * (width // 2) + (offset // 3 % width // 2)) * 3 for offset in indices]
        resized = difference(reduced, image_pixels(sources[0], width // 2, height // 2), reduced_indices)
        require(resized["meanAbsoluteError"] <= 2, "Resized native appearance changed beyond the fixed two-code budget")
        check["resizedAppearance"] = resized
        if color == "rec709" and codec == "h264":
            raw = decoded_frames(delivery, width, height, [0])[0]
            wrong_transfer = difference(raw, expected[0], indices)
            require(wrong_transfer["meanAbsoluteError"] > 4, "Unnormalized BT.709 control did not reject the incorrect comparison domain")
            check["unnormalizedTransferNegativeControl"] = wrong_transfer
            gamma = system_709_gamma()
            grayscale_indices = [offset for offset in indices if (offset // 3 // width // 48) * 4 + (offset // 3 % width // 32) < 6]
            independent = difference(gamma_to_srgb(raw, gamma), expected[0], grayscale_indices)
            require(independent["meanAbsoluteError"] <= 2, "Independent ICC tone-curve math did not preserve neutral gray appearance")
            check["independentSystemICCToneCurve"] = {"gamma": gamma, "measurement": independent,
                                                       "parametersFromDeclaredTags": True, "fittedPixelCalibration": False}
        require(checksum(project) == before, "Appearance checks modified the synthetic project")
        checks.append(check)
    require(all(checksum(source) == digest for source, digest in original.items()), "Appearance checks modified synthetic originals")
    verify_runtime(identity, "after native appearance controls")
    result = {"productAcceptance": False, "comparisonDomain": "native decoded appearance normalized to sRGB",
              "fixedSwatchBudget": 2, "checks": checks, "runtimeIdentity": identity, "sourcesAndProjectsPreserved": True}
    write_json(workspace / "native-color-checks.json", result)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
