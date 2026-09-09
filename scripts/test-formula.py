#!/usr/bin/env python3
"""Validate formula generation offline; does not install, tap, or publish anything."""
import hashlib, pathlib, shutil, subprocess, tempfile
root=pathlib.Path(__file__).resolve().parent.parent
checksum=hashlib.sha256(b"synthetic release fixture").hexdigest()
with tempfile.TemporaryDirectory(prefix="cbm-formula-test-") as temp:
    directory=pathlib.Path(temp)
    (directory/"scripts").mkdir()
    generator=directory/"scripts/update-formula.py"
    shutil.copy(root/"scripts/update-formula.py",generator)
    def run(version="0.1.0",sha=checksum,repo="example/copilot-bridge-menubar"):
        return subprocess.run(["/usr/bin/python3",str(generator),"--version",version,
            "--sha256",sha,"--repository",repo],capture_output=True,text=True)
    assert run().returncode==0
    formula=directory/"Formula/copilot-bridge-menubar.rb"
    text=formula.read_text()
    assert checksum in text and "class CopilotBridgeMenubar < Formula" in text
    assert "cask " not in text
    assert "--foreground" in text and "keep_alive false" in text
    assert run(sha="fake").returncode!=0
    assert run(repo='bad/"injection').returncode!=0
    assert run(version="0.2.0").returncode==0
    assert run(version="0.1.0").returncode!=0
    subprocess.run(["/usr/bin/ruby","-c",str(formula)],check=True)
print("PASS: formula syntax, checksum/repository validation, no downgrade; no publication or installation.")
