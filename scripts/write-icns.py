#!/usr/bin/env python3
import pathlib
import struct
import sys

ENTRIES = {
    "icon_16x16.png": b"icp4",
    "icon_16x16@2x.png": b"ic11",
    "icon_32x32.png": b"icp5",
    "icon_32x32@2x.png": b"ic12",
    "icon_128x128.png": b"ic07",
    "icon_128x128@2x.png": b"ic13",
    "icon_256x256.png": b"ic08",
    "icon_256x256@2x.png": b"ic14",
    "icon_512x512.png": b"ic09",
    "icon_512x512@2x.png": b"ic10",
}


def entry(kind, data):
    return kind + struct.pack(">I", len(data) + 8) + data


def main():
    iconset, output = map(pathlib.Path, sys.argv[1:3])
    body = b"".join(
        entry(kind, (iconset / name).read_bytes()) for name, kind in ENTRIES.items()
    )
    output.write_bytes(entry(b"icns", body))


main()
