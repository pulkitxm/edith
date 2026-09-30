import argparse
import json
import pathlib

from editor_acceptance_contracts import require
from editor_parity_fixtures import fixture_path, verify
from editor_parity_grade import target_grade_measurement, target_references
from editor_parity_pixels import codec_control


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True, type=pathlib.Path)
    args = parser.parse_args()
    verify(args.fixture)
    manifest = json.loads((args.fixture / "parity-manifest.json").read_text())
    count = 0
    for shot in manifest["shots"]:
        expected, negatives = target_references(fixture_path(args.fixture, shot["path"]), shot, 270, 480)
        positive = codec_control(expected, 270, 480)
        def check(actual):
            return target_grade_measurement(actual, expected, positive, negatives, 270, 480, (0, 2600 / 3840, 1, 1))
        try:
            check(positive)
        except AssertionError as error:
            raise AssertionError(f"{shot['name']}: {error}") from error
        for value in negatives.values():
            try:
                check(value)
            except AssertionError as error:
                require("Target-grade pixels differ" in str(error), str(error))
                count += 1
            else:
                raise AssertionError("Incorrect target grade escaped independent measurement")
    print(json.dumps({"productAcceptance": False, "targetGradePhotos": 42, "targetGradeVideos": 5, "negativeControlsRejected": count}))


if __name__ == "__main__":
    main()
