#!/usr/bin/env python3
"""Uses fake device authorization only, with an isolated HOME and blocked network fallback."""
import json, os, pathlib, subprocess, tempfile
root=pathlib.Path(__file__).resolve().parent.parent
bun=os.environ.get("BUN") or str(pathlib.Path.home()/".bun/bin/bun")
for mode in ("success","denied"):
    with tempfile.TemporaryDirectory(prefix="cbm-auth-test-") as home:
        env={"HOME":home,"PATH":"/usr/bin:/bin","CBM_TEST_AUTH":mode,"NO_COLOR":"1"}
        result=subprocess.run([bun,"--preload",str(root/"scripts/mock-auth-preload.ts"),
            "--tsconfig-override",str(root/"tsconfig.json"),str(root/"backend/entry.ts"),"auth"],
            env=env,cwd=root,capture_output=True,text=True,timeout=8)
        events=[json.loads(line[6:]) for line in result.stdout.splitlines() if line.startswith("@@CBM:")]
        assert any(e["kind"]=="authRequired" for e in events),(mode,result.stdout,result.stderr)
        if mode=="success":
            assert result.returncode==0,(result.stdout,result.stderr)
            assert any(e["kind"]=="authSuccess" for e in events)
            credential=pathlib.Path(home)/".local/share/copilot-bridge/github_token"
            assert credential.read_text().strip()=="ghp_FAKE_TEST_CREDENTIAL"
            assert credential.stat().st_mode & 0o777 == 0o600
        else:
            assert result.returncode!=0
            assert any(e["kind"]=="authFailed" for e in events)
        assert "ghp_FAKE_TEST_CREDENTIAL" not in result.stdout+result.stderr
print("PASS: GitHub device-code success, pending and denied; private credential cache; one-shot auth exits.")
