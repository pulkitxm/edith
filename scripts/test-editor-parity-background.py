import argparse
import json
import os
import pathlib
import uuid

from editor_acceptance_contracts import require
from editor_parity_background import background_probe
from editor_parity_cli import invoke
from editor_parity_fixtures import checksum


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ed", required=True, type=pathlib.Path)
    parser.add_argument("--workspace", required=True, type=pathlib.Path)
    args = parser.parse_args()
    binary = checksum(args.ed)
    args.workspace.mkdir()
    environment = {**os.environ, "EDITH_DATA_ROOT": str(args.workspace / "runtime"),
                   "EDITH_SHARED_DEFAULTS_SUITE": f"com.pulkit.edith.background.{uuid.uuid4().hex}"}
    def edit(*arguments, **options):
        return invoke(args.ed, *arguments, environment=environment, **options)
    result = background_probe(edit, args.workspace)
    require(checksum(args.ed) == binary, "CLI changed during native background verification")
    result["binarySHA256"] = binary
    print(json.dumps(result, indent=2))
    require(result["passed"], "Native background fails the independent crop-before-blur encoded-sRGB reference")


if __name__ == "__main__":
    main()
