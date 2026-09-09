#!/usr/bin/env python3
"""Verify an app bundle without opening its UI or starting its backend."""

import argparse
from pathlib import Path
import plistlib
import re
import struct
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--version", required=True)
args = parser.parse_args()
app = args.app
assert app.is_dir() and not app.is_symlink(), "Expected an actual app bundle, not a link"
assert sorted(path.name for path in app.iterdir()) == ["Contents"], "Unexpected bundle root contents"
with (app / "Contents/Info.plist").open("rb") as source:
    info = plistlib.load(source)
assert info["CFBundleIdentifier"] == "com.hyspace.copilot-bridge-menubar"
assert info["CFBundleShortVersionString"] == args.version
assert info["LSUIElement"] is True
# Historical public packages predate the icon. New builds declare it even when
# using a development version; releases from 0.3.0 onward must always include it.
if tuple(map(int, args.version.split("."))) >= (0, 3, 0) or "CFBundleIconFile" in info:
    assert info["CFBundleIconFile"] == "AppIcon.icns"
    icon = (app / "Contents/Resources/AppIcon.icns").read_bytes()
    assert icon[:4] == b"icns" and struct.unpack(">I", icon[4:8])[0] == len(icon), "Invalid app icon"

executable = app / "Contents/MacOS/CopilotBridgeMenuBar"
backend = app / "Contents/Resources/copilot-bridge-service"
for binary in (executable, backend):
    assert binary.is_file() and binary.stat().st_mode & 0o111, f"Not executable: {binary}"
    assert subprocess.check_output(
        ["lipo", "-archs", str(binary)], text=True, timeout=15).strip() == "arm64"
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
               check=True, timeout=60)
assert subprocess.check_output(
    [str(executable), "--version"], text=True, timeout=15).strip() == args.version
revision = (app / "Contents/Resources/bridge-revision.txt").read_text().strip()
assert re.fullmatch(r"[a-f0-9]{40}", revision), "Invalid recorded backend revision"
print(f"PASS: {app} — {args.version}, arm64, signature, bundle resources and backend revision")
