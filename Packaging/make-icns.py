#!/usr/bin/env python3
"""Pack a macOS .iconset into a PNG-backed .icns without external packages."""

from pathlib import Path
import struct
import sys

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

# Apple icon-family types for standard and Retina iconset PNGs.
ICON_TYPES = (
    (b"icp4", "icon_16x16.png", 16),
    (b"icp5", "icon_32x32.png", 32),
    (b"icp6", "icon_32x32@2x.png", 64),
    (b"ic07", "icon_128x128.png", 128),
    (b"ic08", "icon_256x256.png", 256),
    (b"ic09", "icon_512x512.png", 512),
    (b"ic10", "icon_512x512@2x.png", 1024),
    (b"ic11", "icon_16x16@2x.png", 32),
    (b"ic12", "icon_32x32@2x.png", 64),
    (b"ic13", "icon_128x128@2x.png", 256),
    (b"ic14", "icon_256x256@2x.png", 512),
)


def png_chunk(path: Path, expected_size: int) -> bytes:
    data = path.read_bytes()
    if len(data) < 24 or data[:8] != PNG_SIGNATURE or data[12:16] != b"IHDR":
        raise ValueError(f"Invalid PNG: {path}")
    width, height = struct.unpack(">II", data[16:24])
    if width != expected_size or height != expected_size:
        raise ValueError(
            f"Unexpected dimensions for {path}: {width}x{height}, expected {expected_size}x{expected_size}"
        )
    return data


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: make-icns.py iconset-directory output.icns")
    iconset = Path(sys.argv[1])
    output = Path(sys.argv[2])
    chunks = []
    for icon_type, filename, size in ICON_TYPES:
        png = png_chunk(iconset / filename, size)
        chunks.append(icon_type + struct.pack(">I", len(png) + 8) + png)
    body = b"".join(chunks)
    output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


if __name__ == "__main__":
    main()
