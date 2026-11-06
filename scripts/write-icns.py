#!/usr/bin/env python3
import pathlib
import struct
import sys

PNG_LAYERS = {
    b"ic07": "icon_128x128.png",
    b"ic08": "icon_256x256.png",
    b"ic09": "icon_512x512.png",
    b"ic10": "icon_512x512@2x.png",
    b"ic11": "icon_16x16@2x.png",
    b"ic12": "icon_32x32@2x.png",
    b"ic13": "icon_128x128@2x.png",
    b"ic14": "icon_256x256@2x.png",
}


def entry(kind, data):
    return kind + struct.pack(">I", len(data) + 8) + data


def layers(icns):
    offset = 8
    while offset < len(icns):
        kind, size = struct.unpack(">4sI", icns[offset : offset + 8])
        yield kind, icns[offset + 8 : offset + size]
        offset += size


def main():
    iconset, path = map(pathlib.Path, sys.argv[1:3])
    body = b"".join(
        entry(kind, (iconset / PNG_LAYERS[kind]).read_bytes() if kind in PNG_LAYERS else data)
        for kind, data in layers(path.read_bytes())
    )
    path.write_bytes(entry(b"icns", body))


main()
