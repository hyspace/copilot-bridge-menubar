#!/usr/bin/env python3
"""Test package generation offline, without installing or publishing an app."""

import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
checksum = hashlib.sha256(b"synthetic release fixture").hexdigest()
other_checksum = hashlib.sha256(b"different release fixture").hexdigest()

with tempfile.TemporaryDirectory(prefix="cbm-package-test-") as temporary:
    directory = Path(temporary)
    (directory / "scripts").mkdir()
    generator = directory / "scripts/update-cask.py"
    shutil.copy(root / "scripts/update-cask.py", generator)

    def run(version="0.1.0", sha=checksum, repository="example/copilot-bridge-menubar"):
        return subprocess.run(
            [sys.executable, str(generator), "--version", version, "--sha256", sha,
             "--repository", repository], capture_output=True, text=True)

    assert run().returncode == 0
    package = directory / "Casks/copilot-bridge-menubar.rb"
    content = package.read_text()
    assert 'cask "copilot-bridge-menubar" do' in content
    assert f'sha256 "{checksum}"' in content
    assert 'app "Copilot Bridge.app"' in content
    assert 'depends_on arch: :arm64' in content
    assert 'depends_on macos: ">= :sonoma"' in content
    assert "releases/download/v#{version}/Copilot-Bridge-arm64.zip" in content
    assert not any(term in content for term in
                   ("system ", "preflight", "postflight", "launchctl", "no_quarantine", "zap "))
    assert run().returncode == 0
    assert package.read_text() == content
    for version, sha, repository in [
        ("0.1.0", "fake", "example/app"),
        ("0.1.0", checksum, 'bad/"injection'),
        ("0.1.0", checksum, "example/app\n"),
        ("v0.1.0", checksum, "example/app"),
        ("01.1.0", checksum, "example/app"),
        ("1٢.1.0", checksum, "example/app"),
        ("0.1.0", other_checksum, "example/app"),
    ]:
        assert run(version, sha, repository).returncode != 0
        assert package.read_text() == content
    assert run(version="0.2.0", sha=other_checksum).returncode == 0
    upgraded = package.read_text()
    assert run(version="0.1.0").returncode != 0
    assert package.read_text() == upgraded
    assert not list(package.parent.glob("*.tmp"))
    subprocess.run(["/usr/bin/ruby", "-c", str(package)], check=True)
    package.write_text("invalid metadata\n")
    assert run(version="0.3.0").returncode != 0
    assert package.read_text() == "invalid metadata\n"

print("PASS: app package, Ruby syntax, metadata validation, immutable checksums and downgrade protection.")
