#!/usr/bin/env python3
"""Bundle the pinned CLI unchanged. All CLI fixes are committed in the upstream fork."""
import json, os, pathlib, shutil, subprocess
root = pathlib.Path(__file__).resolve().parent.parent
stage = root / ".build" / "backend-stage"
vendor = root / "vendor" / "copilot-bridge"
if not (vendor / "src/lib/events.ts").is_file():
    raise SystemExit("The pinned fork must include supervisor support. Update the submodule.")
bun = os.environ.get("BUN") or shutil.which("bun") or str(pathlib.Path.home()/".bun/bin/bun")
expected = (root/".bun-version").read_text().strip()
actual = subprocess.check_output([bun,"--version"],text=True).strip()
if actual != expected:
    raise SystemExit(f"Build requires Bun {expected}; found {actual}. Update runtime and notices together.")
if stage.exists():
    shutil.rmtree(stage)  # Only our disposable build staging directory.
(stage/"vendor").mkdir(parents=True)
shutil.copytree(root/"backend",stage/"backend")
shutil.copytree(vendor/"src",stage/"vendor/copilot-bridge/src")
shutil.copy(vendor/"package.json",stage/"vendor/copilot-bridge/package.json")
os.symlink((vendor/"node_modules").resolve(),stage/"vendor/copilot-bridge/node_modules")
shutil.copy(root/"tsconfig.json",stage/"tsconfig.json")
(stage/"tests").mkdir()
shutil.copy(vendor/"tests/codex-stream-normalizer.test.ts",stage/"tests")
version=json.loads((vendor/"package.json").read_text())["version"]
out=root/"build/copilot-bridge-service"
out.parent.mkdir(exist_ok=True)
subprocess.run([bun,"build","--compile","--target=bun-darwin-arm64",
    "--define","__BRIDGE_VERSION__="+json.dumps(version),"backend/entry.ts","--outfile",str(out)],
    cwd=stage,check=True)
subprocess.run([bun,"test","tests/codex-stream-normalizer.test.ts"],cwd=stage,check=True)
