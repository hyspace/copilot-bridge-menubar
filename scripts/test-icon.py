#!/usr/bin/env python3
"""Validate the shipped macOS icon container and every standard image size."""
from pathlib import Path
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
icon = root / "resources/AppIcon.icns"
data = icon.read_bytes()
assert data[:4] == b"icns" and struct.unpack(">I", data[4:8])[0] == len(data)
with tempfile.TemporaryDirectory(prefix="cbm-icon-test-") as directory:
    iconset = Path(directory) / "AppIcon.iconset"
    subprocess.run(["/usr/bin/iconutil", "--convert", "iconset", "--output", str(iconset), str(icon)],
                   check=True, timeout=30)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = "@2x" if scale == 2 else ""
            png = (iconset / f"icon_{size}x{size}{suffix}.png").read_bytes()
            assert png[:8] == b"\x89PNG\r\n\x1a\n"
            assert struct.unpack(">II", png[16:24]) == (size * scale, size * scale)
            assert len(png) > 100
print("PASS: AppIcon.icns and all 10 standard/Retina icon images.")
