import argparse
import json
from pathlib import Path

from verify_shipping_host import inspect_host

parser = argparse.ArgumentParser()
parser.add_argument('bundle', type=Path)
parser.add_argument('--release', action='store_true')
args = parser.parse_args()
print(json.dumps(inspect_host(args.bundle, release=args.release), indent=2))
